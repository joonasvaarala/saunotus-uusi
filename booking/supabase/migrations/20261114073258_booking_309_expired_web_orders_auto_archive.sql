-- booking_309: verkkokaupan maksamatta vanhentuneet tilaukset poistuvat näkyvistä (Joonas t1738u 14.11.2026 klo 9.14:
--   "kun verkkokaupan tilaus ja varaus vanhenevat ... ne poistuvat myös meidän järjestelmästä eivätkä näy peruutettuina").
-- Toteutus: booking_279:n poisto = arkistointi automaattisesti (expire_holds-ajo joka minuutti). Rivi, tilaus-/varausnumero, audit-historia ja
--   maksupalveluviitteet säilyvät, jotta myöhäinen maksu löytää maksurivin (Montonio/Visma lookup) ja hälyttää eikä katoa (fyysinen DELETE
--   palauttaisi lookupille found=false → webhook 200 "ignored" = maksu hukkuisi hiljaa).
-- Uudet: booking._expired_web_order_archivable(bigint), booking.expired_web_orders_archive_sweep(integer), asetus expired_unpaid_auto_archive_paused (false),
--   indeksi orders_expired_web_309_idx, notifications_outbox topic late_paid_archived.
-- Laajennus (Joonas 14.11.2026 klo 11.40): myös asiakkaan itse ennen maksua perumat (customer_cancelled_pending, 0 € maksettu) ja asiakasrivit, joilla
--   on vain arkistoituja maksamattomia tilauksia (customers.archived_at, _customer_archivable, admin_list_customers / admin_search_customers).
--   Ensimmäinen ajo (cron, minuutin sisällä) piilottaa nykyiset rivit kerralla.
-- Muutetut: booking.expire_holds() kutsuu sweepin (virhe → warning, pitojen vapautus ei kaadu);
--   booking.admin_get_customer(bigint): asiakkaan tilauslista ja tilausmäärä ohittavat arkistoidut maksamattomat (myöhään maksettu näkyy).
-- Ei koske: hallinnassa tehtyihin tilauksiin (created_by / muu kanava), Pikakassaan, Johkuun, maksettuihin/osin maksettuihin, laskuihin.
-- Ei hinta-/ALV-/URL-muutoksia, ei lippuja, ei asiakasviestejä (vanhentumisviesti lähtee kuten ennen ennen arkistointia), ei public-skeemaa.
-- Rollback: rollbacks/20261114073258_booking_309_ROLLBACK.sql (palauttaa funktiot, purkaa 309:n arkistoinnit external_meta.booking_309:n avulla).
set local lock_timeout = '5s';

do $pre$
declare v text;
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'orders' and column_name = 'archived_at')
     or not exists (select 1 from pg_constraint where conrelid = 'booking.orders'::regclass and conname = 'orders_archived_cancelled')
     or not exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'reservations' and column_name = 'hidden_at') then
    raise exception 'booking_309: booking_279 (archived_at / orders_archived_cancelled) tai reservations.hidden_at puuttuu. Ei muutoksia.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'customers' and column_name in ('archived_at', 'archive_reason'))
     and to_regprocedure('booking._customer_archivable(bigint)') is null then
    raise exception 'booking_309: customers.archived_at/archive_reason on jo olemassa ilman booking_309:ää. Ei muutoksia.';
  end if;
  if to_regclass('booking.notifications_outbox') is null or not exists (select 1 from pg_indexes where schemaname = 'booking' and indexname = 'notifications_outbox_dedupe') then
    raise exception 'booking_309: notifications_outbox / dedupe-indeksi puuttuu. Ei muutoksia.';
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.expire_holds()')));
  if v is null or v not in ('e8a677d847de8669ef8a4070c95abfdd', 'e0c2c3e469565ce6cceb86d816d208cb') then raise exception 'booking_309: booking.expire_holds() md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_get_customer(bigint)')));
  if v is null or v not in ('3753915f420e2819699a1d08a64e4857', 'eedf806570f74419db00b56bc642f094') then raise exception 'booking_309: booking.admin_get_customer(bigint) md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_list_customers(text,integer,integer)')));
  if v is null or v not in ('1ffba8df04ac14a996400bc97182ec21', '33ad761dd85cb6a7f40628ac58dbeb52') then raise exception 'booking_309: booking.admin_list_customers(text,integer,integer) md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_search_customers(text,integer)')));
  if v is null or v not in ('6ab4f8a588a792ca3af0614a20ceb659', 'de91542b1533844550951c154bfc84d9') then raise exception 'booking_309: booking.admin_search_customers(text,integer) md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_mark_paid(text,text,numeric,jsonb)')));
  if v is null or v not in ('b35618b8cd17fa9e7c5902719d0804a2') then raise exception 'booking_309: booking.payment_mark_paid(text,text,numeric,jsonb) md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._expire_holds(bigint,bigint)')));
  if v is null or v not in ('716a9f0236789788b7a6c517d7b5a521') then raise exception 'booking_309: booking._expire_holds(bigint,bigint) md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.gift_cards_housekeeping()')));
  if v is null or v not in ('485836577d7cfc06f9de3660d7150844') then raise exception 'booking_309: booking.gift_cards_housekeeping() md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._email_outbox_archived_bi()')));
  if v is null or v not in ('c8efe598ec100c0b1389fb6a505678db') then raise exception 'booking_309: booking._email_outbox_archived_bi() md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_delete_unpaid_order(bigint,text,boolean)')));
  if v is null or v not in ('3451b8a7d3c340ba93f0d3f93c601127') then raise exception 'booking_309: booking.admin_delete_unpaid_order(bigint,text,boolean) md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_cancel_booking(uuid)')));
  if v is null or v not in ('e945c67903c5091e418131c16e667c04') then raise exception 'booking_309: booking.public_cancel_booking(uuid) md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
  if to_regprocedure('booking._customer_archivable(bigint)') is not null and md5(pg_get_functiondef(to_regprocedure('booking._customer_archivable(bigint)'))) <> '172f72b8587d232e20914c6214b2b4bf' then
    raise exception 'booking_309: booking._customer_archivable(bigint) vieras aiempi versio. Ei muutoksia.';
  end if;
  if to_regprocedure('booking._expired_web_order_archivable(bigint)') is not null and md5(pg_get_functiondef(to_regprocedure('booking._expired_web_order_archivable(bigint)'))) <> '38d0f4093802da2d8caa5d01561cdde6' then
    raise exception 'booking_309: booking._expired_web_order_archivable(bigint) vieras aiempi versio. Ei muutoksia.';
  end if;
  if to_regprocedure('booking.expired_web_orders_archive_sweep(integer)') is not null and md5(pg_get_functiondef(to_regprocedure('booking.expired_web_orders_archive_sweep(integer)'))) <> 'afe9100c20f3d5083e8494d77a100085' then
    raise exception 'booking_309: booking.expired_web_orders_archive_sweep(integer) vieras aiempi versio. Ei muutoksia.';
  end if;
  if to_regprocedure('booking.expired_web_orders_archive_sweep(integer)') is null
     and exists (select 1 from booking.notifications_outbox where topic = 'late_paid_archived') then
    raise exception 'booking_309: topic late_paid_archived on jo käytössä. Ei muutoksia.';
  end if;
end $pre$;

insert into booking.settings(key, value, description, is_public) values
  ('expired_unpaid_auto_archive_paused', 'false'::jsonb,
   'booking_309: true = verkkokaupan maksamatta vanhentuneiden ja asiakkaan ennen maksua perumien tilausten sekä niistä syntyneiden asiakkaiden automaattinen piilotus keskeytetty. Myöhäisen maksun hälytykset ja asiakkaiden palautus näkyviin jatkuvat.', false)
on conflict (key) do nothing;

create index if not exists orders_expired_web_309_idx on booking.orders(id)
  where archived_at is null and source_channel = 'web' and status in ('cancelled', 'expired');

alter table booking.customers add column if not exists archived_at timestamptz;
alter table booking.customers add column if not exists archive_reason text;
create index if not exists customers_archived_309_idx on booking.customers(id) where archived_at is not null;
comment on column booking.customers.archived_at is 'booking_309: asiakas piilotettu listoista, koska hänellä on vain arkistoituja maksamattomia tilauksia. Ehto tarkistetaan listoissa aina uudelleen (booking._customer_archivable).';

-- booking_309: onko tilaus verkkokaupan (asiakkaan itse tekemä) maksamatta vanhentunut tilaus, jolle ei ole tullut yhtään maksua ja jonka voi poistaa
-- näkyvistä ilman että mitään jää orvoksi. Vain luku. Rajaus (Joonas t1738u 14.11.2026):
--  * web-kanava, created_by null (asiakas itse), ei Johku/ulkoinen, ei jo arkistoitu
--  * vanhentunut: (a) tila cancelled ja KAIKKI varaukset cancelled + cancel_reason hold_expired (_expire_holds / booking_70)
--                     tai customer_cancelled_pending (asiakas perui itse ennen maksua, public_cancel_booking; Joonas 14.11. klo 11.40), tai
--                 (b) tila expired ilman varauksia (lahjakorttiostot, gift_cards_housekeeping)
--  * ei yhtään maksua: maksurivit vain cancelled/failed, refunded_amount 0, ei ulkoista/laskumaksua; ei kuitteja, hyvityksiä, kirjanpitojonoa, laskuja
--  * lahjakortit: ostetut kortit cancelled; käytetyn kortin kirjaukset nettona 0 (pito vanheni → osuus palautettu kortille)
--  * kumppanikoodit: lunastukset vain cancelled/expired, ei erotusmaksuja; ei vuosikortteja, koulutusosallistujia, toisen tilauksen lisäpalveluita
--  * sähköpostijonossa ei odottavaa/lähtevää/uudelleenyritettävää viestiä (vanhentumisviesti ehtii lähteä normaalisti ensin)
create or replace function booking._expired_web_order_archivable(p_order_id bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from booking.orders o
     where o.id = p_order_id
       and o.archived_at is null and o.external_source is null and o.johku_order_no is null
       and o.source_channel = 'web' and o.created_by is null
       and o.status in ('cancelled', 'expired') and o.payment_status in ('unpaid', 'pending', 'failed')
       and ((o.status = 'cancelled'
             and exists (select 1 from booking.reservations r where r.order_id = o.id)
             and not exists (select 1 from booking.reservations r where r.order_id = o.id
                              and (r.status <> 'cancelled' or r.cancel_reason is null or r.cancel_reason not in ('hold_expired', 'customer_cancelled_pending'))))
         or (o.status = 'expired' and not exists (select 1 from booking.reservations r where r.order_id = o.id)))
       and not exists (select 1 from booking.payments p where p.order_id = o.id
                        and (p.status not in ('cancelled', 'failed') or coalesce(p.refunded_amount, 0) <> 0
                             or p.external_source is not null or p.method = 'invoice' or p.paid_at is not null))
       and not exists (select 1 from booking.receipts x where x.order_id = o.id)
       and not exists (select 1 from booking.refunds x where x.order_id = o.id)
       and not exists (select 1 from booking.accounting_outbox x where x.order_id = o.id)
       and not exists (select 1 from booking.invoices x where x.order_id = o.id)
       and not exists (select 1 from booking.annual_cards x where x.purchase_order_id = o.id)
       and not exists (select 1 from booking.training_participants x where x.order_id = o.id)
       and not exists (select 1 from booking.voucher_claims v where v.order_id = o.id and v.status not in ('cancelled', 'expired'))
       and not exists (select 1 from booking.vc_difference_payments d where d.order_id = o.id)
       and not exists (select 1 from booking.gift_cards g where g.purchase_order_id = o.id and g.status <> 'cancelled')
       and coalesce((select sum(l.delta) from booking.gift_card_ledger l where l.order_id = o.id), 0) = 0
       and not exists (select 1 from booking.reservations ch join booking.reservations pr on pr.id = ch.parent_reservation_id
                        where pr.order_id = o.id and ch.order_id <> o.id)
       and not exists (select 1 from booking.email_outbox e
                        where (e.order_id = o.id or e.payment_id in (select p.id from booking.payments p where p.order_id = o.id))
                          and e.status in ('pending', 'failed', 'sending')))
$$;

-- booking_309 (Joonas 14.11.2026 klo 11.40, kohta 4): asiakasrivi, joka on syntynyt vain keskeneräisistä kassakäynneistä, piilotetaan asiakaslistasta ja -hausta.
-- Ehto lasketaan aina uudelleen (myös listassa): kun asiakkaalle tulee uusi tilaus, maksu, lahjakortti tms., hän näkyy heti ilman erillistä palautusta.
-- Piiloon vain, jos KAIKKI ehdot: vähintään yksi tilaus ja kaikki tilaukset arkistoitu (archived_at) ilman yhtään maksettua/hyvitettyä maksua;
-- ei vuosikortteja, ostettuja lahjakortteja (paitsi peruttu kortti arkistoidusta tilauksesta), laskutusasiakasrivejä, yhdistämishistoriaa, markkinointilupaa/-historiaa, kampanjalähetyksiä, segmenttejä,
-- muistiinpanoja, yritys-/laskutustietoja, kirjautumistunnusta, henkilökuntamerkintää, ulkoista lähdettä; ei voimassa olevaa jonopaikkaa tai
-- kumppanilunastusta eikä koulutusosallistumista samalla sähköpostilla.
create or replace function booking._customer_archivable(p_customer_id bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from booking.customers c
     where c.id = p_customer_id
       and c.anonymized_at is null and c.merged_into is null and c.external_source is null and c.auth_user_id is null
       and not coalesce(c.customer_type_is_staff, false)
       and coalesce(c.customer_type, 'customer') = 'customer'
       and not coalesce(c.marketing_consent, false) and c.marketing_unsubscribed_at is null
       and nullif(btrim(coalesce(c.notes, '')), '') is null
       and c.business_id is null and c.einvoice_address is null and c.invoice_reference is null
       and coalesce(c.customer_kind, 'private') = 'private'
       and exists (select 1 from booking.orders o where o.customer_id = c.id)
       and not exists (select 1 from booking.orders o where o.customer_id = c.id and o.archived_at is null)
       and not exists (select 1 from booking.orders o join booking.payments p on p.order_id = o.id
                        where o.customer_id = c.id and (p.status in ('paid', 'partially_refunded', 'refunded') or coalesce(p.refunded_amount, 0) <> 0))
       and not exists (select 1 from booking.annual_cards x where x.customer_id = c.id)
       and not exists (select 1 from booking.gift_cards x where x.buyer_customer_id = c.id
                        and (x.status <> 'cancelled' or x.purchase_order_id is null
                             or not exists (select 1 from booking.orders xo where xo.id = x.purchase_order_id and xo.archived_at is not null)))
       and not exists (select 1 from booking.invoice_customers x where x.customer_id = c.id)
       and not exists (select 1 from booking.customer_merge_log x where x.keep_id = c.id or x.merge_id = c.id)
       and not exists (select 1 from booking.customers x where x.merged_into = c.id)
       and not exists (select 1 from booking.marketing_consent_events x where x.customer_id = c.id)
       and not exists (select 1 from booking.campaign_sends x where x.customer_id = c.id)
       and not exists (select 1 from booking.marketing_segment_members x where x.customer_id = c.id)
       and (c.email is null or (
             not exists (select 1 from booking.waitlist_entries w where lower(w.customer_email) = lower(c.email) and w.status in ('waiting', 'notified'))
         and not exists (select 1 from booking.voucher_claims v where lower(v.customer_email) = lower(c.email) and v.status not in ('cancelled', 'expired'))
         and not exists (select 1 from booking.training_participants t where lower(t.email) = lower(c.email)))))
$$;
revoke all on function booking._expired_web_order_archivable(bigint) from public, anon, authenticated;
revoke all on function booking._customer_archivable(bigint) from public, anon, authenticated;

-- booking_309: ajastettu poisto (expire_holds, joka minuutti). Poisto = arkistointi booking_279:n tapaan: rivi, numero ja historia säilyvät,
-- tilaus ja sen varaukset piiloon kaikista tavallisista näkymistä (archived_at / reservations.hidden_at). Ei fyysistä DELETEä (ks. PR).
-- Ei muuta rahaa, kapasiteettia, lahjakortteja eikä viestejä (kaikki tapahtui jo vanhentuessa). Tila expired → cancelled, jotta myöhäinen
-- maksu kulkee booking_263-polkua (ei vahvistusta, tarkistettavaksi) eikä riko orders_archived_cancelled-ehtoa.
-- Myöhäinen maksu arkistoidulle tilaukselle (maksurivi paid/partially_refunded/refunded): hälytys henkilökunnalle notifications_outbox-jonoon
-- (target 'tapio', topic 'late_paid_archived', ref_table 'payments', yksi / maksu) kuten booking_305.
-- Asetus expired_unpaid_auto_archive_paused = true keskeyttää arkistoinnin (hälytykset jatkuvat).
create or replace function booking.expired_web_orders_archive_sweep(p_limit integer default 200)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_paused boolean; r record; o booking.orders; v_n int := 0; v_busy int := 0; v_alerts int := 0;
  v_expected bigint[]; v_locked bigint[]; v_res jsonb; v_pay jsonb; v_reason text; v_cn int := 0; v_cu int := 0;
begin
  if booking._jwt_role() in ('anon', 'authenticated') then perform booking._err('forbidden', 'Vain palvelu'); end if;
  v_paused := coalesce((booking._setting('expired_unpaid_auto_archive_paused', 'false'::jsonb) #>> '{}')::boolean, false);
  if not v_paused then
    for r in
      select x.id from booking.orders x
       where x.archived_at is null and x.source_channel = 'web' and x.created_by is null
         and x.status in ('cancelled', 'expired') and x.payment_status in ('unpaid', 'pending', 'failed')
         and x.external_source is null
       order by x.id
       limit greatest(1, least(coalesce(p_limit, 200), 1000))
    loop
      if not booking._expired_web_order_archivable(r.id) then continue; end if;
      select * into o from booking.orders where id = r.id for update skip locked;
      if not found then v_busy := v_busy + 1; continue; end if;
      select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.payments x where x.order_id = o.id;
      select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
        (select x.id from booking.payments x where x.id = any(v_expected) order by x.id for update skip locked) z;
      if v_expected is distinct from v_locked then v_busy := v_busy + 1; continue; end if;
      select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.reservations x where x.order_id = o.id;
      select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
        (select x.id from booking.reservations x where x.id = any(v_expected) order by x.id for update skip locked) z;
      if v_expected is distinct from v_locked then v_busy := v_busy + 1; continue; end if;
      -- tuore tarkistus lukkojen alla (rinnakkainen maksu / viesti)
      if not booking._expired_web_order_archivable(o.id) then continue; end if;

      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'status', x.status, 'cancel_reason', x.cancel_reason, 'starts_at', x.starts_at) order by x.id), '[]'::jsonb)
        into v_res from booking.reservations x where x.order_id = o.id;
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'status', x.status, 'provider', x.provider, 'method', x.method, 'amount', x.amount) order by x.id), '[]'::jsonb)
        into v_pay from booking.payments x where x.order_id = o.id;

      v_reason := case when exists (select 1 from booking.reservations x where x.order_id = o.id and x.cancel_reason = 'customer_cancelled_pending')
                       then 'auto:customer_cancelled_unpaid' else 'auto:expired_unpaid' end;
      update booking.reservations x
         set hidden_at = coalesce(x.hidden_at, now()), hidden_reason = coalesce(x.hidden_reason, 'expired_unpaid_auto')
       where x.order_id = o.id and x.hidden_at is null;
      update booking.orders
         set status = 'cancelled',
             cancelled_at = coalesce(cancelled_at, now()),
             payment_status = 'unpaid',
             archived_at = now(),
             archived_by = null,
             archive_reason = v_reason,
             external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('booking_309', jsonb_build_object(
               'prev_status', o.status, 'prev_payment_status', o.payment_status, 'prev_cancelled_at', o.cancelled_at, 'at', now()))
       where id = o.id;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
      values (null, coalesce(booking._jwt_role(), 'service_role'), 'orders', o.id::text, 'ORDER_AUTO_ARCHIVED_EXPIRED',
              jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'cancelled_at', o.cancelled_at,
                                 'total_gross', o.total_gross, 'reservations', v_res, 'payments', v_pay),
              jsonb_build_object('order_no', o.order_no, 'status', 'cancelled', 'payment_status', 'unpaid', 'archive_reason', v_reason));
      v_n := v_n + 1;
    end loop;

    -- asiakkaat, joilla on enää vain arkistoituja maksamattomia tilauksia → piiloon (kohta 4)
    for r in
      select c.id from booking.customers c
       where c.archived_at is null and c.anonymized_at is null
         and exists (select 1 from booking.orders x where x.customer_id = c.id and x.archived_at is not null)
       order by c.id
       limit greatest(1, least(coalesce(p_limit, 200), 1000))
    loop
      if not booking._customer_archivable(r.id) then continue; end if;
      update booking.customers set archived_at = now(), archive_reason = 'auto:only_archived_unpaid_orders'
       where id = r.id and archived_at is null;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, coalesce(booking._jwt_role(), 'service_role'), 'customers', r.id::text, 'CUSTOMER_AUTO_ARCHIVED',
              jsonb_build_object('archive_reason', 'auto:only_archived_unpaid_orders',
                                 'order_nos', (select jsonb_agg(x.order_no order by x.order_no) from booking.orders x where x.customer_id = r.id)));
      v_cn := v_cn + 1;
    end loop;
  end if;

  -- piilotettu asiakas, jolle on tullut uusi tilaus / maksu / muu historia → takaisin näkyviin (aina, myös tauolla).
  -- Listat tarkistavat ehdon myös itse, joten näkyvyys palautuu heti; tämä siivoaa merkinnän ja kirjaa auditin.
  for r in
    select c.id from booking.customers c
     where c.archived_at is not null and c.archive_reason = 'auto:only_archived_unpaid_orders'
     order by c.id
  loop
    if booking._customer_archivable(r.id) then continue; end if;
    update booking.customers set archived_at = null, archive_reason = null where id = r.id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, coalesce(booking._jwt_role(), 'service_role'), 'customers', r.id::text, 'CUSTOMER_AUTO_UNARCHIVED', '{}'::jsonb);
    v_cu := v_cu + 1;
  end loop;

  with ins as (
    insert into booking.notifications_outbox(topic, target, ref_table, ref_id, dedupe_key, payload)
    select 'late_paid_archived', 'tapio', 'payments', lp.id, 'late_paid_archived:' || lp.id,
           jsonb_build_object(
             'message', format('Maksu %s € (%s) tuli poistetulle tilaukselle %s. Tilaus pysyy poistettuna: tarkista hallinnassa (Tilaukset → Poistetut) ja palauta maksu tarvittaessa.',
                               replace(to_char(lp.amount, 'FM999999990.00'), '.', ','), coalesce(lp.provider, lp.method), ao.order_no),
             'order_id', ao.id, 'order_no', ao.order_no, 'payment_id', lp.id, 'amount', lp.amount, 'provider', lp.provider,
             'payment_status', lp.status, 'paid_at', lp.paid_at, 'archived_at', ao.archived_at, 'archive_reason', ao.archive_reason)
      from booking.payments lp join booking.orders ao on ao.id = lp.order_id
     where ao.archived_at is not null and lp.status in ('paid', 'partially_refunded', 'refunded')
    on conflict (dedupe_key) do nothing
    returning 1)
  select count(*) into v_alerts from ins;

  return jsonb_build_object('ok', true, 'paused', v_paused, 'archived', v_n, 'skipped_busy', v_busy, 'alerts_queued', v_alerts,
                            'customers_archived', v_cn, 'customers_unarchived', v_cu);
end $$;
revoke all on function booking.expired_web_orders_archive_sweep(integer) from public, anon, authenticated;
grant execute on function booking.expired_web_orders_archive_sweep(integer) to service_role;

CREATE OR REPLACE FUNCTION booking.expire_holds()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer; v_sw jsonb;
begin
  n := booking._expire_holds(null);
  -- booking_309: verkkokaupan maksamatta vanhentuneet tilaukset poistetaan näkyvistä (arkistointi). Virhe ei saa estää pitojen vapautusta.
  begin
    v_sw := booking.expired_web_orders_archive_sweep(200);
  exception when others then
    raise warning 'booking_309: expired_web_orders_archive_sweep epäonnistui: % %', sqlstate, sqlerrm;
  end;
  delete from booking.rate_limit_hits where at < now() - interval '2 days';
  return n;
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_get_customer(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.customers;
begin
  perform booking._require_staff();
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  return to_jsonb(c) - 'unsubscribe_token' - 'customer_type_is_staff' || jsonb_build_object(
    'annual_cards', coalesce((select jsonb_agg(to_jsonb(ac) - 'created_by' - 'revoked_by' order by ac.valid_from desc) from booking.annual_cards ac where ac.customer_id = c.id), '[]'::jsonb),
    'orders', coalesce((
    select jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status,
        'total', o.total_gross, 'created_at', o.created_at, 'channel', o.source_channel,
        'reservations', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'starts_at', r.starts_at, 'persons', r.persons, 'status', r.status,
              'product_name', coalesce(it.product_name, '')) order by r.starts_at), '[]'::jsonb)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null))
      order by o.created_at desc) from booking.orders o where o.customer_id = c.id
        and (o.archived_at is null or exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')))), '[]'::jsonb))  -- booking_309: poistettu (arkistoitu) maksamaton tilaus ei näy
  -- booking_278 (H): asiakasnäkymän tunnusluvut, avoin saldo ja ostetut lahjakortit (koodit maskattuna). Vain lukua.
  || jsonb_build_object(
    'open_balance', coalesce((select sum(b.unpaid) from (select (booking._order_balance(o.id) ->> 'unpaid')::numeric unpaid
        from booking.orders o where o.customer_id = c.id and o.status not in ('cancelled','expired','draft')) b), 0),
    'open_orders', (select count(*) from (select (booking._order_balance(o.id) ->> 'unpaid')::numeric unpaid
        from booking.orders o where o.customer_id = c.id and o.status not in ('cancelled','expired','draft')) b where b.unpaid > 0.004),
    'stats', (select jsonb_build_object(
        'orders', (select count(*) from booking.orders o where o.customer_id = c.id
                     and (o.archived_at is null or exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')))),
        'first_order_at', (select min(o.created_at) from booking.orders o where o.customer_id = c.id),
        'visits', count(*) filter (where r.status = 'completed' or (r.checkin_at is not null and r.status not in ('cancelled','no_show'))),
        'last_visit', max(r.starts_at) filter (where r.status = 'completed' or (r.checkin_at is not null and r.status not in ('cancelled','no_show'))),
        'upcoming', count(*) filter (where r.status in ('pending','confirmed') and r.starts_at > now()),
        'next_at', min(r.starts_at) filter (where r.status in ('pending','confirmed') and r.starts_at > now()),
        'no_show', count(*) filter (where r.status = 'no_show'),
        'last_no_show', max(r.starts_at) filter (where r.status = 'no_show'))
        from booking.reservations r join booking.orders o on o.id = r.order_id
       where o.customer_id = c.id and r.hidden_at is null),
    'gift_cards', jsonb_build_object(
        'bought', coalesce((select jsonb_agg(x.obj order by x.created_at desc) from (
            select g.created_at, jsonb_build_object('id', g.id, 'code_masked', '****-****-' || right(g.code, 4), 'kind', g.kind,
              'initial_amount', g.initial_amount, 'balance', g.balance, 'valid_to', g.valid_to, 'status', g.status, 'created_at', g.created_at) obj
              from booking.gift_cards g where g.buyer_customer_id = c.id order by g.created_at desc limit 50) x), '[]'::jsonb),
        'bought_count', (select count(*) from booking.gift_cards g where g.buyer_customer_id = c.id),
        'bought_total', coalesce((select sum(g.initial_amount) from booking.gift_cards g where g.buyer_customer_id = c.id), 0),
        'redeemed_count', (select count(distinct l.gift_card_id) from booking.gift_card_ledger l join booking.orders o on o.id = l.order_id
                            where o.customer_id = c.id and l.delta < 0)));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_list_customers(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(id bigint, name text, email text, phone text, company text, city text, marketing_consent boolean, marketing_consent_at timestamp with time zone, created_at timestamp with time zone, orders_count bigint, last_visit timestamp with time zone, total_count bigint, customer_type text, customer_kind text, business_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select c.id, c.name, c.email, c.phone, c.company, c.city, c.marketing_consent, c.marketing_consent_at, c.created_at,
           (select count(*) from booking.orders o where o.customer_id = c.id and o.status in ('pending','confirmed','completed')),
           (select max(r.starts_at) from booking.reservations r join booking.orders o on o.id = r.order_id
             where o.customer_id = c.id and r.status in ('confirmed','completed')),
           count(*) over (), c.customer_type, c.customer_kind, c.business_id
      from booking.customers c
     where c.anonymized_at is null
       and (c.archived_at is null or not booking._customer_archivable(c.id))  -- booking_309: vain keskeneräisistä kassakäynneistä syntynyt asiakas piiloon
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%' or c.company ilike '%' || q || '%'
            or c.business_id ilike '%' || q || '%')
     order by c.created_at desc, c.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_search_customers(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_like text; v_digits text; v_norm text;
  v_lim int := least(greatest(coalesce(p_limit, 8), 1), 20);
begin
  perform booking._require_staff();
  if v_s is null or char_length(v_s) < 2 then return '[]'::jsonb; end if;
  v_like := lower('%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%');
  v_digits := nullif(regexp_replace(v_s, '\D', '', 'g'), '');
  v_norm := booking._norm_business_id(v_s);
  if v_norm is not null and not booking._business_id_ok(v_norm) then v_norm := null; end if;
  return coalesce((
    with cust as (
      select 0 as sort, c.created_at as ts, c.id as sid,
             booking._norm_business_id(c.business_id) as nbid, lower(nullif(btrim(c.company), '')) as lco,
             jsonb_build_object(
               'source', 'customer', 'id', c.id, 'customer_id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
               'company', c.company, 'business_id', c.business_id, 'customer_kind', c.customer_kind, 'customer_type', c.customer_type,
               'street', nullif(btrim(c.address), ''), 'zip', nullif(btrim(c.zip), ''), 'city', nullif(btrim(c.city), ''), 'country', c.country,
               'einvoice_address', c.einvoice_address, 'einvoice_operator', c.einvoice_operator, 'invoice_reference', c.invoice_reference
             ) as row
        from booking.customers c
       where c.anonymized_at is null
         and (c.archived_at is null or not booking._customer_archivable(c.id))  -- booking_309: vain keskeneräisistä kassakäynneistä syntynyt asiakas piiloon
         and (lower(c.name) like v_like escape '\'
              or lower(coalesce(c.email, '')) like v_like escape '\'
              or lower(coalesce(c.phone, '')) like v_like escape '\'
              or lower(coalesce(c.company, '')) like v_like escape '\'
              or lower(coalesce(c.business_id, '')) like v_like escape '\'
              or (v_norm is not null and booking._norm_business_id(c.business_id) = v_norm)
              or (v_digits is not null and char_length(v_digits) >= 2
                  and regexp_replace(coalesce(c.business_id, ''), '\D', '', 'g') like '%' || v_digits || '%'))
       order by c.created_at desc, c.id desc
       limit v_lim
    ),
    comp as (
      select 1 as sort, h.last_order_at as ts, h.customer_id as sid,
             jsonb_build_object(
               'source', 'orders', 'id', null, 'customer_id', h.customer_id, 'name', h.contact_name, 'email', h.email, 'phone', h.phone,
               'company', h.company, 'business_id', h.business_id, 'customer_kind', 'company', 'customer_type', null,
               'street', h.street, 'zip', h.zip, 'city', h.city, 'country', h.country,
               'einvoice_address', h.einvoice_address, 'einvoice_operator', h.einvoice_operator,
               'orders_count', h.orders_count, 'last_order_at', h.last_order_at
             ) as row
        from booking._order_company_hits(v_s, v_lim) h
       where not exists (
         select 1 from cust x
          where (h.business_id is not null and x.nbid is not null and x.nbid = booking._norm_business_id(h.business_id))
             or (x.lco is not null and x.lco = lower(h.company))
       )
    )
    select jsonb_agg(u.row order by u.sort, u.ts desc, u.sid)
      from (select sort, ts, sid, row from cust union all select sort, ts, sid, row from comp) u
  ), '[]'::jsonb);
end $function$;

comment on function booking.expired_web_orders_archive_sweep(integer) is 'booking_309: verkkokaupan maksamatta vanhentuneiden tilausten automaattinen poisto näkyvistä (arkistointi) + myöhäisen maksun hälytys (topic late_paid_archived).';
