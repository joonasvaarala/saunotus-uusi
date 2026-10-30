-- Käyttöönoton nollaus ennen 1.11.2026.
--
-- EI migraatio. Tätä tiedostoa ei ajeta automaattisesti, eikä sitä saa ajaa tuotantoon
-- vahingossa. Ylläpitäjä ajaa sen itse tietokannan omistajana (Supabasessa postgres),
-- yhdessä transaktiossa, kun uusi järjestelmä aloittaa puhtaalta pöydältä.
--
-- Poistaa natiivin testidatan: tilaukset, varaukset, rivit, maksut, hyvitykset, kuitit,
-- laskut ja hyvityslaskut, omat lahjakortit ja niiden kirjaukset, maksulinkit ja
-- muistutukset, niihin sidotut sähköposti- ja kirjanpitojonot sekä niitä koskevat
-- audit-rivit. Nollaa kuitti- (K/H/L ja muut sarjat), lasku- ja hyvityslaskusarjat
-- sekä tilausnumeron niin, että seuraava vapaa numero on alkuperäinen alku (10001),
-- ellei säilytetty Johku-tilausnumero ole suurempi — silloin sarja jatkuu sen yläpuolelta,
-- jotta numerot eivät törmää.
--
-- Säilyttää: Johku-tuonnin (external_source, johku_order_no tai source_channel
-- johku_import), tuotteet, hinnat, asetukset, henkilökunnan, työvuorot, tekstit,
-- tapahtumien ja kertojen määritykset, integraatioiden tilan (Montonio, Resend).
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
-- Tarkistus (kaikki natiivimyynti = 0, millä tahansa jaksolla):
--   select booking.cutover_reset_verify();
--
-- Funktiot jäävät kantaan vain tämän ajon jälkeen. Niitä ei ole myönnetty
-- authenticated- eikä service_role-roolille, joten PostgREST ei tarjoa niitä.
-- Ajon jälkeen ne voi poistaa:
--   drop function booking.cutover_reset(boolean), booking.cutover_reset_verify();

create or replace function booking.cutover_reset(p_dry_run boolean default true)
returns jsonb
language plpgsql
volatile
set search_path = pg_temp, booking
as $fn$
declare
  v_dry boolean := coalesce(p_dry_run, true);
  v_counts jsonb := '{}'::jsonb;
  v_kept jsonb;
  v_pdf jsonb := '[]'::jsonb;
  v_n integer;
  v_seq text;
  v_next bigint;
  r record;
  v_storage text := null;
begin
  create temp table if not exists _cut_orders (id bigint primary key) on commit drop;
  create temp table if not exists _cut_payments (id bigint primary key) on commit drop;
  create temp table if not exists _cut_refunds (id bigint primary key) on commit drop;
  create temp table if not exists _cut_receipts (id bigint primary key) on commit drop;
  create temp table if not exists _cut_invoices (id bigint primary key) on commit drop;
  create temp table if not exists _cut_cards (id bigint primary key) on commit drop;
  truncate _cut_orders, _cut_payments, _cut_refunds, _cut_receipts, _cut_invoices, _cut_cards;

  insert into _cut_orders(id)
  select o.id
    from booking.orders o
   where o.external_source is null
     and o.johku_order_no is null
     and o.source_channel is distinct from 'johku_import';

  insert into _cut_payments(id)
  select p.id from booking.payments p where p.order_id in (select id from _cut_orders);

  insert into _cut_refunds(id)
  select f.id from booking.refunds f where f.order_id in (select id from _cut_orders);

  insert into _cut_receipts(id)
  select rc.id from booking.receipts rc where rc.order_id in (select id from _cut_orders);

  insert into _cut_invoices(id)
  select i.id
    from booking.invoices i
   where i.order_id in (select id from _cut_orders)
      or (
        i.order_id is null
        and not exists (
          select 1
            from booking.invoices parent
            join booking.orders o on o.id = parent.order_id
           where parent.id = i.credit_of_id
             and o.id not in (select id from _cut_orders)
        )
      );

  insert into _cut_cards(id)
  select g.id
    from booking.gift_cards g
   where g.source is distinct from 'johku'
     and g.accounting_origin is distinct from 'johku'
     and g.external_source is distinct from 'johku'
     and (g.purchase_order_id is null or g.purchase_order_id in (select id from _cut_orders))
     and not exists (
       select 1 from booking.payments p
        where p.gift_card_id = g.id
          and p.order_id not in (select id from _cut_orders)
     );

  select count(*) into v_n from _cut_orders;
  v_counts := v_counts || jsonb_build_object('orders', v_n);
  select count(*) into v_n from booking.order_items where order_id in (select id from _cut_orders);
  v_counts := v_counts || jsonb_build_object('order_items', v_n);
  select count(*) into v_n from booking.reservations where order_id in (select id from _cut_orders);
  v_counts := v_counts || jsonb_build_object('reservations', v_n);
  if to_regclass('booking.reservation_legs') is not null then
    select count(*) into v_n from booking.reservation_legs l
      join booking.reservations rv on rv.id = l.reservation_id
     where rv.order_id in (select id from _cut_orders);
    v_counts := v_counts || jsonb_build_object('reservation_legs', v_n);
  end if;
  select count(*) into v_n from _cut_payments;
  v_counts := v_counts || jsonb_build_object('payments', v_n);
  select count(*) into v_n from booking.payment_lines where payment_id in (select id from _cut_payments);
  v_counts := v_counts || jsonb_build_object('payment_lines', v_n);
  select count(*) into v_n from _cut_refunds;
  v_counts := v_counts || jsonb_build_object('refunds', v_n);
  select count(*) into v_n from _cut_receipts;
  v_counts := v_counts || jsonb_build_object('receipts', v_n);
  select count(*) into v_n from _cut_invoices;
  v_counts := v_counts || jsonb_build_object('invoices', v_n);
  select count(*) into v_n from booking.invoice_lines where invoice_id in (select id from _cut_invoices);
  v_counts := v_counts || jsonb_build_object('invoice_lines', v_n);
  select count(*) into v_n from _cut_cards;
  v_counts := v_counts || jsonb_build_object('gift_cards', v_n);
  select count(*) into v_n from booking.gift_card_ledger
   where gift_card_id in (select id from _cut_cards)
      or order_id in (select id from _cut_orders)
      or payment_id in (select id from _cut_payments);
  v_counts := v_counts || jsonb_build_object('gift_card_ledger', v_n);
  select count(*) into v_n from booking.email_outbox e
   where e.order_id in (select id from _cut_orders)
      or e.payment_id in (select id from _cut_payments)
      or e.receipt_id in (select id from _cut_receipts);
  v_counts := v_counts || jsonb_build_object('email_outbox', v_n);
  select count(*) into v_n from booking.accounting_outbox a
   where a.order_id in (select id from _cut_orders)
      or a.payment_id in (select id from _cut_payments)
      or a.receipt_id in (select id from _cut_receipts);
  v_counts := v_counts || jsonb_build_object('accounting_outbox', v_n);
  if to_regclass('booking.payment_link_reminders') is not null then
    execute 'select count(*) from booking.payment_link_reminders where payment_id in (select id from pg_temp._cut_payments)' into v_n;
    v_counts := v_counts || jsonb_build_object('payment_link_reminders', v_n);
  end if;
  if to_regclass('booking.montonio_attempts') is not null then
    execute 'select count(*) from booking.montonio_attempts where payment_id in (select id from pg_temp._cut_payments)' into v_n;
    v_counts := v_counts || jsonb_build_object('montonio_attempts', v_n);
  end if;
  if to_regclass('booking.vismapay_attempts') is not null then
    execute 'select count(*) from booking.vismapay_attempts where payment_id in (select id from pg_temp._cut_payments)' into v_n;
    v_counts := v_counts || jsonb_build_object('vismapay_attempts', v_n);
  end if;

  select coalesce(jsonb_agg(x.path), '[]'::jsonb) into v_pdf
    from (
      select rc.pdf_path as path from booking.receipts rc
       where rc.id in (select id from _cut_receipts) and rc.pdf_path is not null
      union
      select i.pdf_path from booking.invoices i
       where i.id in (select id from _cut_invoices) and i.pdf_path is not null
      union
      select g.pdf_path from booking.gift_cards g
       where g.id in (select id from _cut_cards) and g.pdf_path is not null
    ) x;

  select count(*) into v_n
    from booking.customers c
   where c.external_source is null
     and c.external_id is null
     and not exists (select 1 from booking.orders o where o.customer_id = c.id and o.id not in (select id from _cut_orders))
     and not exists (select 1 from booking.gift_cards g where g.buyer_customer_id = c.id and g.id not in (select id from _cut_cards))
     and not exists (select 1 from booking.annual_cards a where a.customer_id = c.id)
     and not exists (select 1 from booking.invoices i where i.customer_id = c.id and i.id not in (select id from _cut_invoices));
  v_counts := v_counts || jsonb_build_object('customers', v_n);

  v_kept := jsonb_build_object(
    'johku_orders', (select count(*) from booking.orders o
                      where o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import'),
    'products', (select count(*) from kb.products),
    'settings', (select count(*) from booking.settings),
    'staff', (select count(*) from booking.staff),
    'site_texts', (select count(*) from booking.site_texts)
  );

  if v_dry then
    return jsonb_build_object(
      'dry_run', true,
      'applied', false,
      'counts', v_counts,
      'kept', v_kept,
      'pdf_paths', v_pdf,
      'note', 'Kuivaharjoitus: rivejä ei poistettu. Poisto: select booking.cutover_reset(false) transaktion sisällä.'
    );
  end if;

  alter table booking.receipts disable trigger receipts_guard;
  alter table booking.gift_card_ledger disable trigger gift_card_ledger_append_only;
  alter table booking.invoices disable trigger invoices_lock;
  alter table booking.invoice_lines disable trigger invoice_lines_lock;

  delete from booking.email_outbox e
     where e.order_id in (select id from _cut_orders)
        or e.payment_id in (select id from _cut_payments)
        or e.receipt_id in (select id from _cut_receipts);

    delete from booking.accounting_outbox a
     where a.order_id in (select id from _cut_orders)
        or a.payment_id in (select id from _cut_payments)
        or a.receipt_id in (select id from _cut_receipts);

    delete from booking.invoice_lines where invoice_id in (select id from _cut_invoices);
    delete from booking.invoices i
     where i.id in (select id from _cut_invoices) and i.credit_of_id is not null;
    delete from booking.invoices where id in (select id from _cut_invoices);

    update booking.receipts
       set original_receipt_id = null
     where id in (select id from _cut_receipts)
       and original_receipt_id is not null;
    delete from booking.receipts where id in (select id from _cut_receipts);

    delete from booking.refunds where id in (select id from _cut_refunds);

    delete from booking.gift_card_ledger where gift_card_id in (select id from _cut_cards);
    update booking.gift_card_ledger
       set order_id = null
     where order_id in (select id from _cut_orders);
    update booking.gift_card_ledger
       set payment_id = null
     where payment_id in (select id from _cut_payments);

    delete from booking.payments where id in (select id from _cut_payments);
    delete from booking.gift_cards where id in (select id from _cut_cards);

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
         and rel.relname not in (
           'gift_cards', 'gift_card_ledger', 'receipts', 'refunds', 'payments',
           'invoices', 'email_outbox', 'accounting_outbox', 'order_items', 'reservations'
         )
    loop
      execute format('delete from %s where %I in (select id from pg_temp._cut_orders)', r.child, r.col);
    end loop;

    delete from booking.orders where id in (select id from _cut_orders);

    delete from booking.customers c
     where c.external_source is null
       and c.external_id is null
       and not exists (select 1 from booking.orders o where o.customer_id = c.id)
       and not exists (select 1 from booking.gift_cards g where g.buyer_customer_id = c.id)
       and not exists (select 1 from booking.annual_cards a where a.customer_id = c.id)
       and not exists (select 1 from booking.invoices i where i.customer_id = c.id);

    update booking.receipt_counters c
       set last_seq = coalesce((select max(rc.seq) from booking.receipts rc where rc.series = c.series and rc.year = c.year), 0);
    update booking.invoice_counters c
       set last_seq = coalesce((select max(i.seq) from booking.invoices i where i.series = c.series), 0);
    insert into booking.invoice_counters(series, last_seq)
    select 'L', 0
     where not exists (select 1 from booking.invoice_counters where series = 'L');

    v_seq := pg_get_serial_sequence('booking.orders', 'order_no');
    if v_seq is not null then
      perform setval(v_seq, greatest(10000, coalesce((select max(o.order_no) from booking.orders o), 10000)), true);
    end if;

    if to_regclass('storage.objects') is not null and jsonb_array_length(v_pdf) > 0 then
      begin
        delete from storage.objects o
         where o.name in (select jsonb_array_elements_text(v_pdf))
            or exists (
              select 1 from jsonb_array_elements_text(v_pdf) p(path)
               where o.name = p.path or o.name like '%/' || p.path
            );
      exception
        when insufficient_privilege or undefined_table then
          v_storage := sqlerrm;
      end;
    end if;

    delete from booking.audit_log a
     where a.action is distinct from 'CUTOVER_RESET'
       and (
         (a.table_name = 'orders' and a.row_pk in (select id::text from _cut_orders))
         or (a.table_name = 'payments' and a.row_pk in (select id::text from _cut_payments))
         or (a.table_name = 'refunds' and a.row_pk in (select id::text from _cut_refunds))
         or (a.table_name = 'receipts' and a.row_pk in (select id::text from _cut_receipts))
         or (a.table_name = 'invoices' and a.row_pk in (select id::text from _cut_invoices))
         or (a.table_name = 'gift_cards' and a.row_pk in (select id::text from _cut_cards))
         or (a.new_data ->> 'order_id') in (select id::text from _cut_orders)
         or (a.old_data ->> 'order_id') in (select id::text from _cut_orders)
       );

    alter table booking.receipts enable trigger receipts_guard;
    alter table booking.gift_card_ledger enable trigger gift_card_ledger_append_only;
    alter table booking.invoices enable trigger invoices_lock;
    alter table booking.invoice_lines enable trigger invoice_lines_lock;

    if exists (
      select 1
        from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'booking'
         and t.tgname in ('receipts_guard', 'gift_card_ledger_append_only', 'invoices_lock', 'invoice_lines_lock')
         and t.tgenabled = 'D'
    ) then
      raise exception 'cutover_reset: guard-trigger jäi pois päältä';
    end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), current_user), 'orders', 'cutover', 'CUTOVER_RESET',
          jsonb_build_object('counts', v_counts, 'kept', v_kept, 'at', now()));

  if v_seq is not null then
    execute format('select case when is_called then last_value + 1 else last_value end from %s', v_seq)
      into v_next;
  end if;

  return jsonb_build_object(
    'dry_run', false,
    'applied', true,
    'counts', v_counts,
    'kept', v_kept,
    'pdf_paths', v_pdf,
    'storage_note', v_storage,
    'next_order_no', v_next,
    'verify', booking.cutover_reset_verify()
  );
end $fn$;

create or replace function booking.cutover_reset_verify()
returns jsonb
language plpgsql
stable
security definer
set search_path = booking
as $fn$
declare
  v_native integer;
  v_receipts integer;
  v_rep jsonb;
  v_acc jsonb;
  v_gross numeric;
  v_refunds numeric;
  v_sales numeric := 0;
  v_acc_refunds numeric := 0;
  v_adv numeric := 0;
  v_gc numeric := 0;
  v_rc_max integer;
  v_inv_max integer;
  v_rc_left integer;
  v_inv_left integer;
  v_ok boolean;
begin
  select count(*) into v_native
    from booking.orders o
   where o.external_source is null
     and o.johku_order_no is null
     and o.source_channel is distinct from 'johku_import';
  select count(*) into v_receipts
    from booking.receipts r
   where not booking._acct_excluded(r.order_id, r.payment_id);
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
  select coalesce(max(last_seq), 0) into v_rc_max from booking.receipt_counters;
  select coalesce(max(last_seq), 0) into v_inv_max from booking.invoice_counters;
  select coalesce(max(seq), 0) into v_rc_left from booking.receipts;
  select coalesce(max(seq), 0) into v_inv_left from booking.invoices;
  v_ok := v_native = 0
      and v_receipts = 0
      and v_gross = 0
      and v_refunds = 0
      and coalesce((v_rep #>> '{totals,receipts}')::int, 0) = 0
      and v_sales = 0
      and v_acc_refunds = 0
      and v_adv = 0
      and v_gc = 0
      and v_rc_max = v_rc_left
      and v_inv_max = v_inv_left;
  return jsonb_build_object(
    'ok', v_ok,
    'native_orders', v_native,
    'native_receipts', v_receipts,
    'payment_report_gross', v_gross,
    'payment_report_refunds', v_refunds,
    'payment_report_receipts', coalesce((v_rep #>> '{totals,receipts}')::int, 0),
    'accrual_sales_gross', v_sales,
    'accrual_refunds_gross', v_acc_refunds,
    'advances_services_gross', v_adv,
    'gift_cards_unused_gross', v_gc,
    'receipt_counter_max', v_rc_max,
    'invoice_counter_max', v_inv_max,
    'johku_orders', (select count(*) from booking.orders o
                      where o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import'),
    'note', 'Natiivimyynti on 0 jaksolla 2000-01-01–2099-12-31 sekä kassaperusteisessa että suoriteperusteisessa raportissa. Johku ei ole natiivimyyntiä.'
  );
end $fn$;

revoke all on function booking.cutover_reset(boolean) from public, anon, authenticated, service_role;
revoke all on function booking.cutover_reset_verify() from public, anon, authenticated, service_role;

comment on function booking.cutover_reset(boolean) is
  'Kertaluonteinen käyttöönoton nollaus. p_dry_run true (oletus) vain laskee. false poistaa natiivit testitositteet yhdessä kutsujan transaktiossa. Ei PostgREST-oikeuksia.';
comment on function booking.cutover_reset_verify() is
  'Nollauksen jälkeen: natiivit tilaukset ja kuitit 0, kassa- ja suoriteraportin myynti 0 koko aikajänteellä.';

-- Oletus on kuivaharjoitus. Älä vaihda tätä riviksi cutover_reset(false).
select booking.cutover_reset(true);
