-- Käyttöönoton nollaus ennen 1.11.2026.
--
-- EI migraatio. Tätä tiedostoa ei ajeta automaattisesti, eikä sitä saa ajaa tuotantoon
-- vahingossa. Ylläpitäjä ajaa sen itse tietokannan omistajana (Supabasessa postgres),
-- yhdessä transaktiossa, kun uusi järjestelmä aloittaa puhtaalta pöydältä.
--
-- Sääntö (Joonas): jokainen uudessa järjestelmässä tehty tilaus, varaus, asiakas, maksu
-- ja lahjakortti on testi. Nollauksen jälkeen jäljellä on vain Johku-lähtöinen data
-- (tilaukset, varaukset, asiakkaat, lahjakortit) sekä tuotteet, hinnat, asetukset,
-- henkilökunta, työvuorot, sulut, tekstit, alennuskoodit ja integraatioiden tila.
--
-- Poistaa (kaikki, mikä ei ole Johku-tilaukseen sidottu):
--   tilaukset, rivit, varaukset ja niiden osat, tilauspyynnöt, maksut ja maksurivit,
--   maksuyritykset (Montonio, Visma Pay), maksulinkkimuistutukset, hyvitykset, kuitit,
--   laskut, laskurivit, laskujen lähetysloki, laskuasiakkaat, omat lahjakortit ja
--   niiden kirjaukset (myös Johku-kortin kirjaukset testitilauksilta, saldo palautetaan),
--   vuosikortit, natiivit asiakkaat (ja niiden markkinointisuostumukset), kaikki
--   sähköposti- ja kirjanpitojonon rivit, joita ei ole sidottu Johku-tilaukseen,
--   jonotuslistan, yritystarjouspyynnöt, upsell- ja analytiikkatapahtumat,
--   lahjakorttihakujen lokin, rate limit -rivit, orvoiksi jäävät ilmoitukset
--   (notifications_outbox) sekä audit-rivit kaikista poistetuista riveistä.
-- Laskee alennuskoodien käyttökerrat uudelleen jäljelle jäävistä tilauksista.
-- Nollaa kuittisarjat (K, H ja muut) ja laskusarjan L: seuraava numero on 1.
-- Tilausnumero: ensimmäinen uusi tilaus saa numeron 15000 (sovittu). Jos Johku-
-- tilausnumero olisi >= 15000, ajo keskeytyy.
--
-- Storage-tiedostoja (kuitti- ja lasku-PDF:t) EI poisteta SQL:llä (Supabase estää sen,
-- ja tiedosto jäisi). Funktio palauttaa listan storage_objects (bucket + polku);
-- poista ne Storage-API:lla: booking/scripts/cutover_storage_cleanup.mjs
-- tai Supabase Dashboard → Storage. HUOM: laskujen välimuisti on nimetty
-- laskunumerolla (L000001.pdf), joten vanhat testi-PDF:t on poistettava ennen
-- ensimmäistä oikeaa laskua.
--
-- Muuttumattomat taulut (receipts_guard, invoices_lock, invoice_lines_lock,
-- gift_card_ledger_append_only) ohitetaan vain tämän transaktion ajaksi
-- (DISABLE TRIGGER / ENABLE TRIGGER). Virhe kytkee triggerit takaisin ja peruuttaa
-- koko transaktion, kun kutsu on begin/commit-lohkossa.
--
-- Kuivaharjoitus (ei poista, tulostaa määrät tauluittain) — tiedoston loppu tekee tämän:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f booking/scripts/reset_before_launch.sql
--
-- Poisto:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
--   begin;
--   select booking.cutover_reset(false);
--   select booking.cutover_reset_verify();
--   commit;
--   SQL
--
-- Tarkistus (ok = tietokanta puhdas, storage_ok = PDF:t poistettu):
--   select booking.cutover_reset_verify();
--
-- Funktiot jäävät kantaan vain tämän ajon jälkeen. Niitä ei ole myönnetty
-- authenticated- eikä service_role-roolille, joten PostgREST ei tarjoa niitä.
-- Ajon jälkeen ne voi poistaa:
--   drop function booking.cutover_reset(boolean), booking.cutover_reset_verify(),
--                 booking._cutover_storage_orphans();

-- Yksityisten bucketien tiedostot, joihin mikään jäljelle jäävä rivi ei viittaa.
create or replace function booking._cutover_storage_orphans()
returns table(bucket text, path text)
language sql
stable
security definer
set search_path = ''
as $fn$
  select o.bucket_id::text, o.name::text
    from storage.objects o
    join storage.buckets b on b.id = o.bucket_id and not b.public
   where not exists (select 1 from booking.receipts r
                      where o.name in (r.pdf_path, r.receipt_no || '.pdf'))
     and not exists (select 1 from booking.invoices i
                      where o.name in (i.pdf_path, i.invoice_no || '.pdf'))
     and not exists (select 1 from booking.gift_cards g where o.name = g.pdf_path)
   order by 1, 2
$fn$;

create or replace function booking.cutover_reset(p_dry_run boolean default true)
returns jsonb
language plpgsql
volatile
set search_path = pg_temp, booking
as $fn$
declare
  c_first_order_no constant bigint := 15000;
  v_dry boolean := coalesce(p_dry_run, true);
  v_counts jsonb;
  v_kept jsonb;
  v_storage jsonb := '[]'::jsonb;
  v_storage_err text := null;
  v_max_kept bigint;
  v_seq text;
  v_next bigint;
  r record;
  t text;
begin
  create temp table if not exists _keep_orders (id bigint primary key) on commit drop;
  create temp table if not exists _cut (tbl text, id bigint, primary key (tbl, id)) on commit drop;
  truncate _keep_orders, _cut;

  insert into _keep_orders(id)
  select o.id from booking.orders o
   where o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import';

  -- Tilaukset ja niiden lapset
  insert into _cut select 'orders', o.id from booking.orders o where o.id not in (select id from _keep_orders);
  insert into _cut select 'order_items', oi.id from booking.order_items oi
   where oi.order_id in (select id from _cut where tbl = 'orders');
  insert into _cut select 'reservations', rv.id from booking.reservations rv
   where rv.order_id in (select id from _cut where tbl = 'orders')
      or (rv.order_id is null and rv.external_source is distinct from 'johku');
  insert into _cut select 'reservation_legs', l.id from booking.reservation_legs l
   where l.reservation_id in (select id from _cut where tbl = 'reservations');
  insert into _cut select 'order_requests', q.id from booking.order_requests q
   where q.order_id in (select id from _cut where tbl = 'orders');
  insert into _cut select 'voucher_claims', v.id from booking.voucher_claims v
   where v.order_id in (select id from _cut where tbl = 'orders');
  insert into _cut select 'vc_difference_payments', v.id from booking.vc_difference_payments v
   where v.order_id in (select id from _cut where tbl = 'orders');

  -- Maksut (Johku-tilauksilla ei ole maksuja; kaikki muu on natiivia)
  insert into _cut select 'payments', p.id from booking.payments p
   where p.external_source is distinct from 'johku'
     and (p.order_id is null or p.order_id not in (select id from _keep_orders));
  insert into _cut select 'payment_lines', pl.id from booking.payment_lines pl
   where pl.payment_id in (select id from _cut where tbl = 'payments');
  -- ei id-saraketta: merkitään määrä negatiivisena
  insert into _cut select 'montonio_attempts', -x.n from (select count(*) n from booking.montonio_attempts m
   where m.payment_id is null or m.payment_id in (select id from _cut where tbl = 'payments')) x where x.n > 0;
  insert into _cut select 'vismapay_attempts', -x.n from (select count(*) n from booking.vismapay_attempts m
   where m.payment_id is null or m.payment_id in (select id from _cut where tbl = 'payments')) x where x.n > 0;
  insert into _cut select 'payment_link_reminders', m.id from booking.payment_link_reminders m
   where m.payment_id in (select id from _cut where tbl = 'payments');
  insert into _cut select 'refunds', f.id from booking.refunds f
   where f.order_id not in (select id from _keep_orders)
      or f.payment_id in (select id from _cut where tbl = 'payments');
  insert into _cut select 'receipts', rc.id from booking.receipts rc
   where rc.order_id is null or rc.order_id not in (select id from _keep_orders)
      or rc.payment_id in (select id from _cut where tbl = 'payments')
      or rc.refund_id in (select id from _cut where tbl = 'refunds');

  -- Laskut: kaikki, joita ei ole sidottu Johku-tilaukseen
  insert into _cut select 'invoices', i.id from booking.invoices i
   where (i.order_id is null or i.order_id not in (select id from _keep_orders))
     and not exists (select 1 from booking.invoices parent
                      where parent.id = i.credit_of_id and parent.order_id in (select id from _keep_orders));
  insert into _cut select 'invoice_lines', il.id from booking.invoice_lines il
   where il.invoice_id in (select id from _cut where tbl = 'invoices');
  insert into _cut select 'invoice_dispatch_log', d.id from booking.invoice_dispatch_log d
   where d.invoice_id in (select id from _cut where tbl = 'invoices');
  insert into _cut select 'invoice_customers', ic.id from booking.invoice_customers ic
   where not exists (select 1 from booking.invoices i
                      where i.customer_id = ic.id and i.id not in (select id from _cut where tbl = 'invoices'));

  -- Lahjakortit: natiivit, joita mikään säilyvä maksu ei käytä
  insert into _cut select 'gift_cards', g.id from booking.gift_cards g
   where g.source is distinct from 'johku'
     and g.accounting_origin is distinct from 'johku'
     and g.external_source is distinct from 'johku'
     and (g.purchase_order_id is null or g.purchase_order_id not in (select id from _keep_orders))
     and not exists (select 1 from booking.payments p
                      where p.gift_card_id = g.id and p.id not in (select id from _cut where tbl = 'payments'));
  insert into _cut select 'gift_card_ledger', l.id from booking.gift_card_ledger l
   where l.gift_card_id in (select id from _cut where tbl = 'gift_cards')
      or l.order_id in (select id from _cut where tbl = 'orders')
      or l.payment_id in (select id from _cut where tbl = 'payments');

  -- Vuosikortit ja asiakkaat
  insert into _cut select 'annual_cards', a.id from booking.annual_cards a
   where a.purchase_order_id in (select id from _cut where tbl = 'orders')
      or a.customer_id in (select c.id from booking.customers c where c.external_source is null and c.external_id is null);
  insert into _cut select 'customers', c.id from booking.customers c
   where c.external_source is null and c.external_id is null
     and not exists (select 1 from booking.orders o where o.customer_id = c.id and o.id in (select id from _keep_orders))
     and not exists (select 1 from booking.gift_cards g where g.buyer_customer_id = c.id
                      and g.id not in (select id from _cut where tbl = 'gift_cards'))
     and not exists (select 1 from booking.annual_cards a where a.customer_id = c.id
                      and a.id not in (select id from _cut where tbl = 'annual_cards'));

  -- Jonot: kaikki, mitä ei ole sidottu Johku-tilaukseen
  insert into _cut select 'email_outbox', e.id from booking.email_outbox e
   where e.order_id is null or e.order_id not in (select id from _keep_orders)
      or e.payment_id in (select id from _cut where tbl = 'payments')
      or e.receipt_id in (select id from _cut where tbl = 'receipts');
  insert into _cut select 'accounting_outbox', a.id from booking.accounting_outbox a
   where a.order_id is null or a.order_id not in (select id from _keep_orders)
      or a.payment_id in (select id from _cut where tbl = 'payments')
      or a.receipt_id in (select id from _cut where tbl = 'receipts');

  -- Vain uuden järjestelmän tauluja (ennen käyttöönottoa kaikki rivit ovat testejä)
  foreach t in array array['upsell_events', 'waitlist_entries', 'waitlist_notify_log', 'waitlist_session_state',
                           'business_quote_requests', 'gift_card_check_log', 'rate_limit_hits',
                           'analytics_events', 'analytics_daily_counts', 'analytics_monthly']
  loop
    if to_regclass('booking.' || t) is not null
       and exists (select 1 from information_schema.columns
                    where table_schema = 'booking' and table_name = t and column_name = 'id') then
      execute format('insert into pg_temp._cut select %L, id from booking.%I', t, t);
    elsif to_regclass('booking.' || t) is not null then
      execute format('select count(*) from booking.%I', t) into v_next;
      if v_next > 0 then insert into _cut values (t, -v_next); end if;  -- ei id-saraketta: merkitään määrä
    end if;
  end loop;

  select coalesce(jsonb_object_agg(x.tbl, x.n), '{}'::jsonb) into v_counts
    from (select tbl, sum(case when id < 0 then -id else 1 end)::bigint n from _cut group by tbl order by tbl) x;

  -- Yksityisten bucketien tiedostot, joihin mikään säilyvä rivi ei viittaa nollauksen jälkeen
  begin
    select coalesce(jsonb_agg(jsonb_build_object('bucket', o.bucket_id, 'path', o.name) order by o.bucket_id, o.name), '[]'::jsonb)
      into v_storage
      from storage.objects o
      join storage.buckets b on b.id = o.bucket_id and not b.public
     where not exists (select 1 from booking.receipts rc
                        where rc.id not in (select id from _cut where tbl = 'receipts')
                          and o.name in (rc.pdf_path, rc.receipt_no || '.pdf'))
       and not exists (select 1 from booking.invoices i
                        where i.id not in (select id from _cut where tbl = 'invoices')
                          and o.name in (i.pdf_path, i.invoice_no || '.pdf'))
       and not exists (select 1 from booking.gift_cards g
                        where g.id not in (select id from _cut where tbl = 'gift_cards')
                          and o.name = g.pdf_path);
  exception when others then
    v_storage_err := sqlerrm;
  end;

  select max(o.order_no) into v_max_kept from booking.orders o where o.id in (select id from _keep_orders);
  v_kept := jsonb_build_object(
    'johku_orders', (select count(*) from _keep_orders),
    'max_johku_order_no', v_max_kept,
    'products', (select count(*) from kb.products),
    'settings', (select count(*) from booking.settings),
    'staff', (select count(*) from booking.staff),
    'site_texts', (select count(*) from booking.site_texts),
    'discount_codes', (select count(*) from booking.discount_codes),
    'johku_gift_cards', (select count(*) from booking.gift_cards g where g.id not in (select id from _cut where tbl = 'gift_cards'))
  );

  if coalesce(v_max_kept, 0) >= c_first_order_no then
    raise exception 'cutover_reset: Johku-tilausnumero % >= %, tilausnumerot törmäisivät', v_max_kept, c_first_order_no;
  end if;

  if v_dry then
    return jsonb_build_object(
      'dry_run', true,
      'applied', false,
      'counts', v_counts,
      'kept', v_kept,
      'next_order_no', c_first_order_no,
      'storage_objects', v_storage,
      'storage_note', v_storage_err,
      'note', 'Kuivaharjoitus: rivejä ei poistettu. Poisto: select booking.cutover_reset(false) transaktion sisällä.'
    );
  end if;

  alter table booking.receipts disable trigger receipts_guard;
  alter table booking.gift_card_ledger disable trigger gift_card_ledger_append_only;
  alter table booking.invoices disable trigger invoices_lock;
  alter table booking.invoice_lines disable trigger invoice_lines_lock;

  -- Alennuskoodit, joita testitilaukset käyttivät (lasketaan uudelleen lopussa)
  create temp table if not exists _cut_codes (id bigint primary key) on commit drop;
  truncate _cut_codes;
  insert into _cut_codes
  select distinct x.code_id from (
    select o.discount_code_id code_id from booking.orders o where o.id in (select id from _cut where tbl = 'orders')
    union all
    select oi.discount_code_id from booking.order_items oi where oi.id in (select id from _cut where tbl = 'order_items')
  ) x where x.code_id is not null;

  -- Johku-lahjakortin saldo takaisin, jos testitilaus käytti sitä
  update booking.gift_cards g
     set balance = g.balance - d.delta,
         status = case when g.status = 'used' and g.balance - d.delta > 0 then 'active' else g.status end
    from (select l.gift_card_id, sum(l.delta) delta from booking.gift_card_ledger l
           where l.id in (select id from _cut where tbl = 'gift_card_ledger')
             and l.gift_card_id not in (select id from _cut where tbl = 'gift_cards')
           group by 1) d
   where g.id = d.gift_card_id;

  delete from booking.waitlist_notify_log where id in (select id from _cut where tbl = 'waitlist_notify_log');
  delete from booking.waitlist_entries where id in (select id from _cut where tbl = 'waitlist_entries');
  delete from booking.waitlist_session_state;
  delete from booking.email_outbox where id in (select id from _cut where tbl = 'email_outbox');
  delete from booking.accounting_outbox where id in (select id from _cut where tbl = 'accounting_outbox');
  delete from booking.invoice_lines where id in (select id from _cut where tbl = 'invoice_lines');
  delete from booking.invoices where id in (select id from _cut where tbl = 'invoices') and credit_of_id is not null;
  delete from booking.invoices where id in (select id from _cut where tbl = 'invoices');
  update booking.receipts set original_receipt_id = null
   where id in (select id from _cut where tbl = 'receipts') and original_receipt_id is not null;
  delete from booking.receipts where id in (select id from _cut where tbl = 'receipts');
  delete from booking.refunds where id in (select id from _cut where tbl = 'refunds');
  delete from booking.gift_card_ledger where id in (select id from _cut where tbl = 'gift_card_ledger');
  -- order_items.gift_card_id (NO ACTION) estäisi lahjakortin poiston ennen tilausta
  update booking.order_items set gift_card_id = null
   where id in (select id from _cut where tbl = 'order_items') and gift_card_id is not null;
  delete from booking.montonio_attempts where payment_id is null or payment_id in (select id from _cut where tbl = 'payments');
  delete from booking.vismapay_attempts where payment_id is null or payment_id in (select id from _cut where tbl = 'payments');
  delete from booking.payments where id in (select id from _cut where tbl = 'payments');
  delete from booking.gift_cards where id in (select id from _cut where tbl = 'gift_cards');
  delete from booking.reservations where id in (select id from _cut where tbl = 'reservations') and order_id is null;

  -- muut tilauksiin viittaavat taulut, joiden FK ei kaskadoi
  for r in
    select c.conrelid::regclass as child, a.attname as col, rel.relname as relname
      from pg_constraint c
      join pg_class rel on rel.oid = c.conrelid
      join pg_namespace n on n.oid = rel.relnamespace
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.confrelid = 'booking.orders'::regclass
       and c.contype = 'f'
       and coalesce(array_length(c.conkey, 1), 0) = 1
       and n.nspname = 'booking'
       and c.confdeltype in ('a', 'r')
       and rel.relname not in ('gift_cards', 'gift_card_ledger', 'receipts', 'refunds', 'payments',
                               'invoices', 'email_outbox', 'accounting_outbox', 'order_items', 'reservations')
  loop
    execute format('delete from %s where %I in (select id from pg_temp._cut where tbl = %L)', r.child, r.col, 'orders');
  end loop;
  delete from booking.orders where id in (select id from _cut where tbl = 'orders');
  delete from booking.annual_cards where id in (select id from _cut where tbl = 'annual_cards');
  delete from booking.customers where id in (select id from _cut where tbl = 'customers');
  delete from booking.invoice_customers where id in (select id from _cut where tbl = 'invoice_customers');

  foreach t in array array['upsell_events', 'business_quote_requests', 'gift_card_check_log', 'rate_limit_hits',
                           'analytics_events', 'analytics_daily_counts', 'analytics_monthly']
  loop
    if to_regclass('booking.' || t) is not null then
      execute format('delete from booking.%I', t);
    end if;
  end loop;

  -- Alennuskoodien käyttökerrat jäljelle jäävistä tilauksista
  update booking.discount_codes d
     set used_count = (select count(distinct o.id) from booking.orders o
                         left join booking.order_items oi on oi.order_id = o.id
                        where (o.discount_code_id = d.id or oi.discount_code_id = d.id)
                          and o.status not in ('cancelled', 'expired'))
   where d.id in (select id from _cut_codes);

  -- Ilmoitukset, joiden kohde poistui
  for r in select distinct n.ref_table from booking.notifications_outbox n where n.ref_table is not null loop
    t := regexp_replace(r.ref_table, '^booking\.', '');
    if to_regclass('booking.' || t) is not null
       and exists (select 1 from information_schema.columns
                    where table_schema = 'booking' and table_name = t and column_name = 'id') then
      execute format('delete from booking.notifications_outbox n where n.ref_table = %L and n.ref_id is not null
                       and not exists (select 1 from booking.%I x where x.id = n.ref_id)', r.ref_table, t);
    end if;
  end loop;

  -- Numerosarjat: kuitit ja laskut alkavat 1:stä, tilaukset 15000:sta
  update booking.receipt_counters c
     set last_seq = coalesce((select max(rc.seq) from booking.receipts rc where rc.series = c.series and rc.year = c.year), 0);
  update booking.invoice_counters c
     set last_seq = coalesce((select max(i.seq) from booking.invoices i where i.series = c.series), 0);
  insert into booking.invoice_counters(series, last_seq)
  select 'L', 0 where not exists (select 1 from booking.invoice_counters where series = 'L');
  v_seq := pg_get_serial_sequence('booking.orders', 'order_no');
  if v_seq is null then
    raise exception 'cutover_reset: orders.order_no-sekvenssiä ei löydy';
  end if;
  perform setval(v_seq, c_first_order_no, false);

  -- Audit: poistettujen rivien historia (myös poiston aikana syntyneet DELETE-rivit)
  delete from booking.audit_log a
   where a.action is distinct from 'CUTOVER_RESET'
     and (
       exists (select 1 from _cut c
                where c.tbl = regexp_replace(a.table_name, '^booking\.', '') and c.id::text = a.row_pk)
       or (a.new_data ->> 'order_id') in (select id::text from _cut where tbl = 'orders')
       or (a.old_data ->> 'order_id') in (select id::text from _cut where tbl = 'orders')
       or (a.new_data ->> 'payment_id') in (select id::text from _cut where tbl = 'payments')
       or (a.old_data ->> 'payment_id') in (select id::text from _cut where tbl = 'payments')
       or (a.new_data ->> 'customer_id') in (select id::text from _cut where tbl = 'customers')
       or (a.old_data ->> 'customer_id') in (select id::text from _cut where tbl = 'customers')
     );
  -- ja aiemmin poistettujen testirivien historia (rivi ei enää ole olemassa)
  foreach t in array array['orders', 'order_items', 'reservations', 'reservation_legs', 'order_requests',
                           'payments', 'payment_lines', 'refunds', 'receipts', 'invoices', 'invoice_lines',
                           'invoice_customers', 'gift_cards', 'gift_card_ledger', 'customers', 'annual_cards',
                           'voucher_claims', 'business_quote_requests']
  loop
    execute format('delete from booking.audit_log a
                     where a.action is distinct from %L
                       and regexp_replace(a.table_name, ''^booking\.'', '''') = %L
                       and a.row_pk ~ ''^[0-9]+$''
                       and not exists (select 1 from booking.%I x where x.id = a.row_pk::bigint)',
                   'CUTOVER_RESET', t, t);
  end loop;

  alter table booking.receipts enable trigger receipts_guard;
  alter table booking.gift_card_ledger enable trigger gift_card_ledger_append_only;
  alter table booking.invoices enable trigger invoices_lock;
  alter table booking.invoice_lines enable trigger invoice_lines_lock;
  if exists (
    select 1
      from pg_trigger tg
      join pg_class c on c.oid = tg.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'booking'
       and tg.tgname in ('receipts_guard', 'gift_card_ledger_append_only', 'invoices_lock', 'invoice_lines_lock')
       and tg.tgenabled = 'D'
  ) then
    raise exception 'cutover_reset: guard-trigger jäi pois päältä';
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), current_user), 'orders', 'cutover', 'CUTOVER_RESET',
          jsonb_build_object('counts', v_counts, 'kept', v_kept, 'at', now()));

  execute format('select case when is_called then last_value + 1 else last_value end from %s', v_seq) into v_next;
  return jsonb_build_object(
    'dry_run', false,
    'applied', true,
    'counts', v_counts,
    'kept', v_kept,
    'storage_objects', v_storage,
    'storage_note', coalesce(v_storage_err, 'Poista storage_objects Storage-API:lla (scripts/cutover_storage_cleanup.mjs) commitin jälkeen.'),
    'next_order_no', v_next,
    'verify', booking.cutover_reset_verify()
  );
end $fn$;

create or replace function booking.cutover_reset_verify()
returns jsonb
language plpgsql
volatile
security definer
set search_path = booking
as $fn$
declare
  c_first_order_no constant bigint := 15000;
  v_left jsonb;
  v_bad jsonb;
  v_rep jsonb;
  v_acc jsonb;
  v_gross numeric;
  v_refunds numeric;
  v_sales numeric := 0;
  v_acc_refunds numeric := 0;
  v_adv numeric := 0;
  v_gc numeric := 0;
  v_seq text;
  v_next bigint;
  v_native_orders bigint;
  v_storage bigint := null;
  v_rc_bad bigint;
  v_ic_bad bigint;
  v_dc_bad bigint;
  v_audit_bad bigint := 0;
  v_n bigint;
  v_ok boolean;
  t text;
begin
  create temp table if not exists _verify_keep (id bigint primary key) on commit drop;
  truncate _verify_keep;
  insert into _verify_keep select o.id from booking.orders o
   where o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import';

  select count(*) into v_native_orders from booking.orders o where o.id not in (select id from _verify_keep);

  v_left := jsonb_build_object(
    'orders', v_native_orders,
    'order_items', (select count(*) from booking.order_items oi where oi.order_id not in (select id from _verify_keep)),
    'reservations', (select count(*) from booking.reservations rv
                      where (rv.order_id is null and rv.external_source is distinct from 'johku')
                         or rv.order_id not in (select id from _verify_keep)),
    'order_requests', (select count(*) from booking.order_requests q where q.order_id not in (select id from _verify_keep)),
    'payments', (select count(*) from booking.payments p where p.external_source is distinct from 'johku'),
    'payment_lines', (select count(*) from booking.payment_lines),
    'montonio_attempts', (select count(*) from booking.montonio_attempts),
    'vismapay_attempts', (select count(*) from booking.vismapay_attempts),
    'payment_link_reminders', (select count(*) from booking.payment_link_reminders),
    'refunds', (select count(*) from booking.refunds),
    'receipts', (select count(*) from booking.receipts),
    'invoices', (select count(*) from booking.invoices),
    'invoice_lines', (select count(*) from booking.invoice_lines),
    'invoice_customers', (select count(*) from booking.invoice_customers),
    'gift_cards_native', (select count(*) from booking.gift_cards g
                           where g.source is distinct from 'johku' and g.accounting_origin is distinct from 'johku'
                             and g.external_source is distinct from 'johku'),
    'gift_card_ledger_native', (select count(*) from booking.gift_card_ledger l
                                 where l.order_id is not null and l.order_id not in (select id from _verify_keep)
                                    or l.payment_id is not null),
    'annual_cards', (select count(*) from booking.annual_cards),
    'customers_native', (select count(*) from booking.customers c where c.external_source is null and c.external_id is null),
    'email_outbox', (select count(*) from booking.email_outbox e
                      where e.order_id is null or e.order_id not in (select id from _verify_keep)),
    'accounting_outbox', (select count(*) from booking.accounting_outbox a
                           where a.order_id is null or a.order_id not in (select id from _verify_keep)),
    'voucher_claims', (select count(*) from booking.voucher_claims),
    'vc_difference_payments', (select count(*) from booking.vc_difference_payments),
    'upsell_events', (select count(*) from booking.upsell_events),
    'waitlist_entries', (select count(*) from booking.waitlist_entries),
    'waitlist_notify_log', (select count(*) from booking.waitlist_notify_log),
    'business_quote_requests', (select count(*) from booking.business_quote_requests),
    'gift_card_check_log', (select count(*) from booking.gift_card_check_log),
    'analytics_events', (select count(*) from booking.analytics_events)
  );

  -- Ilmoitukset, joiden kohde puuttuu
  v_n := 0;
  for t in select distinct regexp_replace(n.ref_table, '^booking\.', '') from booking.notifications_outbox n where n.ref_table is not null loop
    if to_regclass('booking.' || t) is not null
       and exists (select 1 from information_schema.columns
                    where table_schema = 'booking' and table_name = t and column_name = 'id') then
      execute format('select count(*) from booking.notifications_outbox n
                       where regexp_replace(n.ref_table, ''^booking\.'', '''') = %L and n.ref_id is not null
                         and not exists (select 1 from booking.%I x where x.id = n.ref_id)', t, t) into v_audit_bad;
      v_n := v_n + v_audit_bad;
    end if;
  end loop;
  v_left := v_left || jsonb_build_object('notifications_dangling', v_n);

  -- Audit-rivit poistetuista tilaus-, maksu- ja asiakasriveistä
  v_n := 0;
  foreach t in array array['orders', 'order_items', 'reservations', 'reservation_legs', 'order_requests',
                           'payments', 'payment_lines', 'refunds', 'receipts', 'invoices', 'invoice_lines',
                           'invoice_customers', 'gift_cards', 'gift_card_ledger', 'customers', 'annual_cards',
                           'voucher_claims', 'business_quote_requests']
  loop
    execute format('select count(*) from booking.audit_log a
                     where a.action is distinct from ''CUTOVER_RESET''
                       and regexp_replace(a.table_name, ''^booking\.'', '''') = %L
                       and a.row_pk ~ ''^[0-9]+$''
                       and not exists (select 1 from booking.%I x where x.id = a.row_pk::bigint)', t, t) into v_audit_bad;
    v_n := v_n + v_audit_bad;
  end loop;
  v_left := v_left || jsonb_build_object('audit_rows_of_deleted', v_n);

  -- Numerosarjat ja alennuskoodit
  select count(*) into v_rc_bad from booking.receipt_counters c
   where c.last_seq <> coalesce((select max(rc.seq) from booking.receipts rc where rc.series = c.series and rc.year = c.year), 0);
  select count(*) into v_ic_bad from booking.invoice_counters c
   where c.last_seq <> coalesce((select max(i.seq) from booking.invoices i where i.series = c.series), 0);
  select count(*) into v_dc_bad from booking.discount_codes d
   where d.used_count <> (select count(distinct o.id) from booking.orders o
                            left join booking.order_items oi on oi.order_id = o.id
                           where (o.discount_code_id = d.id or oi.discount_code_id = d.id)
                             and o.status not in ('cancelled', 'expired'));
  v_seq := pg_get_serial_sequence('booking.orders', 'order_no');
  if v_seq is not null then
    execute format('select case when is_called then last_value + 1 else last_value end from %s', v_seq) into v_next;
  end if;

  begin
    select count(*) into v_storage from booking._cutover_storage_orphans();
  exception when others then
    v_storage := null;
  end;

  -- Raportit: natiivimyynti 0 koko aikajänteellä
  v_rep := booking._report_json('2000-01-01'::date, '2099-12-31'::date, false, false);
  v_gross := coalesce((v_rep #>> '{totals,gross}')::numeric, 0);
  v_refunds := coalesce((v_rep #>> '{totals,refunds_gross}')::numeric, 0);
  if to_regprocedure('booking._accrual_json(date,date,date)') is not null then
    v_acc := booking._accrual_json('2000-01-01'::date, '2099-12-31'::date, '2099-12-31'::date);
    v_sales := coalesce((v_acc #>> '{totals,sales_gross}')::numeric, 0);
    v_acc_refunds := coalesce((v_acc #>> '{totals,refunds_gross}')::numeric, 0);
    v_adv := coalesce((v_acc #>> '{advances,services,gross}')::numeric, 0);
    v_gc := coalesce((v_acc #>> '{advances,gift_cards_unused,gross}')::numeric, 0);
  end if;

  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_bad
    from jsonb_each(v_left) e(k, v) where (v #>> '{}')::bigint <> 0;

  v_ok := v_bad = '{}'::jsonb
      and v_rc_bad = 0
      and v_ic_bad = 0
      and v_dc_bad = 0
      and v_gross = 0
      and v_refunds = 0
      and coalesce((v_rep #>> '{totals,receipts}')::int, 0) = 0
      and v_sales = 0
      and v_acc_refunds = 0
      and v_adv = 0
      and v_gc = 0
      and (v_native_orders > 0 or v_next = c_first_order_no);

  return jsonb_build_object(
    'ok', v_ok,
    'storage_ok', coalesce(v_storage, -1) = 0,
    'storage_objects_left', v_storage,
    'not_zero', v_bad,
    'left', v_left,
    'receipt_counters_wrong', v_rc_bad,
    'invoice_counters_wrong', v_ic_bad,
    'receipt_counters', (select jsonb_object_agg(series || '-' || year, last_seq) from booking.receipt_counters),
    'invoice_counters', (select jsonb_object_agg(series, last_seq) from booking.invoice_counters),
    'discount_codes_wrong', v_dc_bad,
    'next_order_no', v_next,
    'next_order_no_expected', c_first_order_no,
    'payment_report_gross', v_gross,
    'payment_report_refunds', v_refunds,
    'payment_report_receipts', coalesce((v_rep #>> '{totals,receipts}')::int, 0),
    'accrual_sales_gross', v_sales,
    'accrual_refunds_gross', v_acc_refunds,
    'advances_services_gross', v_adv,
    'gift_cards_unused_gross', v_gc,
    'johku_orders', (select count(*) from _verify_keep),
    'note', 'ok = tietokannassa vain Johku-data, sarjat nollattu, seuraava tilausnumero 15000. storage_ok = yksityisissä bucketeissa ei orpoja PDF-tiedostoja.'
  );
end $fn$;

revoke all on function booking._cutover_storage_orphans() from public, anon, authenticated, service_role;
revoke all on function booking.cutover_reset(boolean) from public, anon, authenticated, service_role;
revoke all on function booking.cutover_reset_verify() from public, anon, authenticated, service_role;
comment on function booking.cutover_reset(boolean) is
  'Kertaluonteinen käyttöönoton nollaus. p_dry_run true (oletus) vain laskee. false poistaa kaiken ei-Johku-datan yhdessä kutsujan transaktiossa ja asettaa seuraavan tilausnumeron 15000:ksi. Ei PostgREST-oikeuksia.';
comment on function booking.cutover_reset_verify() is
  'Nollauksen jälkeen: ei ei-Johku-rivejä, kuitti- ja laskusarjat alusta, seuraava tilausnumero 15000, natiivimyynti 0 raporteissa.';
-- Oletus on kuivaharjoitus. Älä vaihda tätä riviksi cutover_reset(false).
select booking.cutover_reset(true);
