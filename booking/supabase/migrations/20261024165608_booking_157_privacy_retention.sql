-- booking_157: tietosuojan säilytysajat (tietosuojaseloste §6, tarkistukset.md huomio 1 ja 2). Väliaikainen versio 20261024165608.
-- 1) Kävijämittaus: booking.analytics_monthly (kuukausikooste ilman session_key-, order_id- ja UTM-tekstisarakkeita).
--    booking.analytics_cleanup() koostaa poistettavat (yli 13 kk) raakatapahtumat SAMASSA lauseessa ennen poistoa (delete ... returning),
--    joten jokainen tapahtuma on joko raakana tai koosteessa, ei molemmissa. Alle 5 tapahtuman ryhmät yhdistetään: ensin polku → '/muu',
--    sitten kieli/laite/lähde → 'muu' ja tuote → -1. Uniikit istunnot = päiväkohtaiset uniikit summattuina.
--    booking.admin_analytics_summary lukee koosteen ja raakadatan yhdessä; ilman koostekuukausia tulos on täsmälleen booking_150:n.
--    Menneisyyteen osuva aikaväli saa olla enintään 3661 päivää (tulevaisuuteen ulottuva yhä enintään 367).
-- 2) Asiakasrekisterin henkilötiedot (asiakas, varaus, tilaus, lahjakortti, vuosikortti, jonotus, yritystarjous, kampanjaloki, kb.leads)
--    anonymisoidaan 3 v asiakkaan viimeisimmästä tapahtumasta. 3) Kirjanpitoaineiston henkilökentät poistetaan vasta, kun 6 v on kulunut
--    sen kalenterivuoden lopusta, jona tilikausi päättyi (tilikauden loppu asetuksena, oletus 12-31). Summat, päivät, tuotteet, maksutavat säilyvät.
--    email_outbox.payload ja audit_log tyhjennetään henkilötiedoista.
-- 4) booking.privacy_retention_report(p_as_of) = kuivaharjoitus (ei kirjoituksia), booking.privacy_retention_run() = ajo
--    (vain admin / service_role / pg_cron, asetus privacy_retention.enabled = false oletuksena → ajo ei tee mitään). Ajastus käsin:
--    booking/supabase/manual/booking_157_retention_cron.sql.
-- TURVA: aktiivisia (voimassa, ei vanhentunut, saldo > 0) lahjakortteja, voimassa olevia vuosikortteja, tulevia varauksia tai
--    avoimia maksuja/palautuksia/laskuja/pyyntöjä/lunastuksia ei kosketa; asiakas, jolla on jokin niistä, ohitetaan kokonaan.
-- Kirjanpitolukot (receipts_guard_trg, invoices_lock_trg) sallivat vain kapean poikkeuksen: GUC booking.privacy_retention = 'on'
--    JA tosite on jo yli 6 v säilytysajan JA vain henkilökentät muuttuvat. Muuten lukot toimivat kuten ennen.
-- Ei muuta public-skeemaa eikä kb.products/public_catalog-rakenteita. Uudelleenajettava.
-- Rollback: booking/supabase/rollbacks/20261024165608_booking_157_ROLLBACK.sql (palauttaa 4 funktiota tuotannon md5:n mukaisiksi).
set local lock_timeout = '5s';

-- ===== asetukset =====
insert into booking.settings(key, value, description) values
 ('privacy_retention.enabled', 'false'::jsonb, 'booking_157: tietosuojan säilytysajo (privacy_retention_run) päällä? Oletus false: ajo ei muuta mitään.'),
 ('privacy_retention.fiscal_year_end', '"12-31"'::jsonb, 'booking_157: tilikauden päättymispäivä MM-DD (oletus kalenterivuosi 12-31). Tositteiden 6 v lasketaan sen vuoden lopusta, jona tilikausi päättyi.'),
 ('privacy_retention.customer_years', '3'::jsonb, 'booking_157: asiakasrekisterin henkilötiedot anonymisoidaan näin monen vuoden kuluttua viimeisimmästä tapahtumasta (seloste §6).'),
 ('privacy_retention.accounting_years', '6'::jsonb, 'booking_157: kirjanpitoaineiston henkilökentät poistetaan, kun näin monta vuotta on kulunut tilikauden päättymisvuoden lopusta.'),
 ('privacy_retention.email_outbox_months', '12'::jsonb, 'booking_157: lähetettyjen/päättyneiden sähköpostien payload (vastaanottaja, linkit) tyhjennetään näin monen kuukauden jälkeen.'),
 ('analytics_k_min', '5'::jsonb, 'booking_157: kävijämittauksen kuukausikoosteen pienin ryhmä; pienemmät yhdistetään (polku → /muu, muut ulottuvuudet → muu).')
on conflict (key) do nothing;

-- ===== kuukausikooste =====
create table if not exists booking.analytics_monthly (
  month            date not null check (month = date_trunc('month', month)::date),
  kind             text not null check (kind in ('event', 'visit', 'unique')),
  event_type       text not null,
  path             text not null,
  locale           text not null,
  device_type      text not null,
  source_category  text not null,
  product_id       bigint not null default 0,
  events           integer not null default 0 check (events >= 0),
  checkouts        integer not null default 0 check (checkouts >= 0),
  purchases        integer not null default 0 check (purchases >= 0),
  orders           integer not null default 0 check (orders >= 0),
  amount_gross_sum numeric(14,2) not null default 0,
  updated_at       timestamptz not null default now(),
  primary key (month, kind, event_type, path, locale, device_type, source_category, product_id)
);
comment on table booking.analytics_monthly is 'booking_157: kävijämittauksen kuukausikooste yli 13 kk vanhoista tapahtumista. Ei istunto-, tilaus- eikä UTM-tekstitietoja. '
  'kind=event: tapahtumat ulottuvuuksittain (product_id 0 = ei tuotetta, -1 = muu/yhdistetty); kind=visit: käynnit (istunnon ensimmäinen sivu, päiväkohtainen) '
  'lähteen/laitteen/kielen mukaan, checkouts/purchases = istunnot; kind=unique: päiväkohtaiset uniikit istunnot tapahtumatyypeittäin summattuina, purchase-rivillä orders + amount_gross_sum.';
alter table booking.analytics_monthly enable row level security;
revoke all on booking.analytics_monthly from public, anon, authenticated;
grant select, insert, update, delete on booking.analytics_monthly to service_role;

-- ===== ajoloki =====
create table if not exists booking.privacy_retention_runs (
  id          bigint generated always as identity primary key,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  as_of       date not null,
  enabled     boolean not null,
  actor       uuid,
  actor_role  text,
  status      text not null check (status in ('disabled', 'ok', 'partial')),
  counts      jsonb not null default '{}'::jsonb,
  errors      jsonb not null default '[]'::jsonb
);
comment on table booking.privacy_retention_runs is 'booking_157: privacy_retention_run-ajojen loki (vain määrät, ei henkilötietoja).';
alter table booking.privacy_retention_runs enable row level security;
revoke all on booking.privacy_retention_runs from public, anon, authenticated;
grant select on booking.privacy_retention_runs to authenticated;
grant select, insert, update on booking.privacy_retention_runs to service_role;
drop policy if exists privacy_retention_runs_admin_read on booking.privacy_retention_runs;
create policy privacy_retention_runs_admin_read on booking.privacy_retention_runs for select to authenticated using (booking.is_admin());

-- ===== apufunktiot =====
create or replace function booking._privacy_int(p_key text, p_default integer, p_min integer, p_max integer)
returns integer language sql stable security definer set search_path = '' as $$
  select case when v ~ '^\d{1,4}$' and v::integer between p_min and p_max then v::integer else p_default end
    from (select (select s.value #>> '{}' from booking.settings s where s.key = p_key) v) x
$$;
create or replace function booking._privacy_fy_end_mmdd()
returns text language sql stable security definer set search_path = '' as $$
  select case when v ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' then v else '12-31' end
    from (select (select s.value #>> '{}' from booking.settings s where s.key = 'privacy_retention.fiscal_year_end') v) x
$$;
-- Kirjanpitovuosi: tilikausi, johon päivä kuuluu, päättyy vuonna acct_year. Säilytys päättyy acct_year + N vuoden lopussa.
create or replace function booking._privacy_acct_year(p_day date)
returns integer language sql stable security definer set search_path = '' as $$
  select extract(year from p_day)::integer + case when to_char(p_day, 'MM-DD') <= booking._privacy_fy_end_mmdd() then 0 else 1 end
$$;
-- true, kun p_day:n tositteen 6 v (asetus) säilytysaika on päättynyt p_as_of-päivään mennessä.
create or replace function booking._privacy_acct_due(p_day date, p_as_of date default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_day is not null and extract(year from coalesce(p_as_of, (now() at time zone 'Europe/Helsinki')::date))::integer
         > booking._privacy_acct_year(p_day) + booking._privacy_int('privacy_retention.accounting_years', 6, 1, 50)
$$;
revoke all on function booking._privacy_int(text, integer, integer, integer) from public, anon, authenticated;
revoke all on function booking._privacy_fy_end_mmdd() from public, anon, authenticated;
revoke all on function booking._privacy_acct_year(date) from public, anon, authenticated;
revoke all on function booking._privacy_acct_due(date, date) from public, anon;
grant execute on function booking._privacy_acct_due(date, date) to authenticated, service_role;
grant execute on function booking._privacy_int(text, integer, integer, integer), booking._privacy_fy_end_mmdd(), booking._privacy_acct_year(date) to service_role;

-- Sallittu ajaja: pg_cron / postgres (ei JWT:tä), service_role tai admin.
create or replace function booking._privacy_require_admin()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(booking._jwt_role(), 'service_role') = 'service_role' then return; end if;
  if not booking.is_admin() then perform booking._err('forbidden', 'Vain ylläpitäjä'); end if;
end $$;
revoke all on function booking._privacy_require_admin() from public, anon, authenticated;
grant execute on function booking._privacy_require_admin() to service_role;

-- ===== henkilötietoavaimet audit_logia varten (sama lista kuin _privacy_candidates-lohkon pii-CTE:ssä; node-testi vertaa) =====
create or replace function booking._privacy_pii_keys()
returns table(tbl text, cats text[], keys text[], acct boolean) language sql immutable set search_path = '' as $$
  values
  ('customers', array['customers'], array['name', 'email', 'phone', 'company', 'address', 'zip', 'city', 'notes', 'business_id', 'einvoice_address', 'einvoice_operator', 'invoice_reference', 'auth_user_id'], false),
  ('reservations', array['reservations_3y'], array['notes', 'cancel_reason', 'therapist_exception_note', 'override_reason', 'hidden_reason'], false),
  ('order_requests', array['order_requests_3y'], array['reason', 'note', 'payload'], false),
  ('voucher_claims', array['voucher_claims_3y'], array['customer_name', 'customer_email', 'customer_phone', 'notes'], false),
  ('gift_cards', array['gift_cards_3y'], array['buyer_name', 'buyer_email', 'recipient_name', 'recipient_email', 'greeting', 'cover_message', 'note'], false),
  ('annual_cards', array['annual_cards_3y'], array['notes'], false),
  ('waitlist_entries', array['waitlist_3y'], array['customer_name', 'customer_email', 'customer_phone'], false),
  ('business_quote_requests', array['quotes_3y'], array['company_name', 'contact_name', 'email', 'phone', 'message', 'admin_note', 'offering_other', 'preferred_when'], false),
  ('campaign_sends', array['campaign_sends_3y'], array['email'], false),
  ('orders', array['orders_3y', 'orders_6y'], array['customer_note', 'internal_note', 'billing', 'invoice_reference'], true),
  ('payments', array['payments_6y'], array['raw', 'note', 'link_url'], true),
  ('refunds', array['refunds_6y'], array['reason', 'raw'], true),
  ('receipts', array['receipts_6y'], array['snapshot', 'text_body'], true),
  ('invoices', array['invoices_6y'], array['customer_snapshot', 'notes', 'buyer_reference'], true),
  ('invoice_customers', array['invoice_customers_6y'], array['contact_name', 'email', 'phone', 'buyer_reference'], true),
  ('invoice_dispatch_log', array['invoice_dispatch_log_6y'], array['payload'], true),
  ('accounting_exports', array['accounting_exports_6y'], array['request', 'response'], true),
  ('gift_card_ledger', array['gift_card_ledger_6y'], array['note'], true)
$$;
revoke all on function booking._privacy_pii_keys() from public, anon, authenticated;
grant execute on function booking._privacy_pii_keys() to service_role;

-- ===== ehdokkaat: yksi SQL-lohko, jota sekä raportti että ajo käyttävät (ja jonka tuotannon lukuversio
--       booking/supabase/manual/booking_157_retention_report_readonly.sql sisältää sellaisenaan) =====
create or replace function booking._privacy_candidates(p_as_of date)
returns table(category text, id bigint, blocked text) language sql stable security definer set search_path = '' as $fn$
with p0 as (select p_as_of as as_of),
-- <privacy-candidates>
p as (
  select x.as_of,
         (x.as_of::timestamp at time zone 'Europe/Helsinki') as as_of_ts,
         ((x.as_of - make_interval(years => x.cy))::timestamp at time zone 'Europe/Helsinki') as cut3,
         ((x.as_of - make_interval(months => x.em))::timestamp at time zone 'Europe/Helsinki') as cut_mail,
         ((x.as_of - make_interval(months => x.am))) as cut_analytics,
         extract(year from x.as_of)::integer - x.ay - 1 as max_acct_year,
         x.fye
    from (select p0.as_of,
                 coalesce((select case when s.value #>> '{}' ~ '^\d{1,4}$' and (s.value #>> '{}')::integer between 1 and 50 then (s.value #>> '{}')::integer end
                             from booking.settings s where s.key = 'privacy_retention.customer_years'), 3) as cy,
                 coalesce((select case when s.value #>> '{}' ~ '^\d{1,4}$' and (s.value #>> '{}')::integer between 1 and 50 then (s.value #>> '{}')::integer end
                             from booking.settings s where s.key = 'privacy_retention.accounting_years'), 6) as ay,
                 coalesce((select case when s.value #>> '{}' ~ '^\d{1,4}$' and (s.value #>> '{}')::integer between 1 and 600 then (s.value #>> '{}')::integer end
                             from booking.settings s where s.key = 'privacy_retention.email_outbox_months'), 12) as em,
                 coalesce((select case when s.value #>> '{}' ~ '^\d{1,4}$' and (s.value #>> '{}')::integer >= 1 then (s.value #>> '{}')::integer end
                             from booking.settings s where s.key = 'analytics_retention_months'), 13) as am,
                 coalesce((select case when s.value #>> '{}' ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' then s.value #>> '{}' end
                             from booking.settings s where s.key = 'privacy_retention.fiscal_year_end'), '12-31') as fye
            from p0) x
),
-- Tilauskohtaiset päivät ja esteet (avoimet maksut, palautukset, laskut, pyynnöt, lunastukset, kirjanpitoviennit, tulevat varaukset).
ord as (
  select o.id, o.customer_id,
         greatest(o.created_at, o.confirmed_at, o.cancelled_at, r.mx, y.mx, f.mx, v.mx, q.mx, i.mx, rc.mx) as latest,
         ((greatest(o.created_at, o.confirmed_at, o.cancelled_at, y.acct, f.mx, i.mx, rc.mx)) at time zone 'Europe/Helsinki')::date as acct_day,
         case when coalesce(r.fut, false) then 'future_reservation'
              when o.status in ('draft', 'pending') or o.payment_status in ('pending', 'partially_paid') then 'open_order'
              when coalesce(y.open, false) then 'open_payment'
              when coalesce(f.open, false) then 'open_refund'
              when coalesce(i.open, false) then 'open_invoice'
              when coalesce(q.open, false) then 'open_request'
              when coalesce(v.open, false) then 'open_voucher_claim'
              when coalesce(ao.open, false) then 'open_accounting' end as blocked
    from booking.orders o cross join p
    left join lateral (select max(r.ends_at) as mx, bool_or(r.ends_at >= p.as_of_ts and r.status not in ('cancelled', 'expired')) as fut
                         from booking.reservations r where r.order_id = o.id) r on true
    left join lateral (select max(greatest(y.created_at, y.paid_at, y.link_expires_at)) as mx, max(greatest(y.created_at, y.paid_at)) as acct,
                              bool_or(y.status = 'pending') as open
                         from booking.payments y where y.order_id = o.id) y on true
    left join lateral (select max(greatest(f.created_at, f.done_at)) as mx, bool_or(f.status in ('requested', 'processing')) as open
                         from booking.refunds f where f.order_id = o.id) f on true
    left join lateral (select max(greatest(v.created_at, v.resolved_at, v.hold_until)) as mx, bool_or(v.status in ('open', 'processing')) as open
                         from booking.voucher_claims v where v.order_id = o.id) v on true
    left join lateral (select max(greatest(q.created_at, q.handled_at)) as mx, bool_or(q.status = 'open') as open
                         from booking.order_requests q where q.order_id = o.id) q on true
    left join lateral (select max(greatest(i.invoice_date::timestamp at time zone 'Europe/Helsinki', i.paid_at, i.voided_at, i.sent_at)) as mx,
                              bool_or(i.status in ('draft', 'sent', 'overdue')) as open
                         from booking.invoices i where i.order_id = o.id) i on true
    left join lateral (select max(rc.issued_at) as mx from booking.receipts rc where rc.order_id = o.id) rc on true
    left join lateral (select bool_or(a.status in ('pending', 'processing', 'needs_review')) as open
                         from booking.accounting_outbox a where a.order_id = o.id) ao on true
),
gc as (
  select g.id, coalesce(g.buyer_customer_id, o.customer_id) as cid,
         greatest(g.created_at, g.activated_at, g.last_used_at, g.delivered_at,
                  (g.valid_to + 1)::timestamp at time zone 'Europe/Helsinki',
                  (g.deliver_on + 1)::timestamp at time zone 'Europe/Helsinki',
                  (select max(l.at) from booking.gift_card_ledger l where l.gift_card_id = g.id)) as latest,
         (g.status = 'active' and g.balance > 0 and (g.valid_to is null or g.valid_to >= p.as_of)) as is_active,
         (g.status in ('pending_verification', 'pending_payment')) as is_pending,
         (g.buyer_name is not null or g.buyer_email is not null or g.recipient_name is not null
          or coalesce(g.recipient_email, 'poistettu@anonymisoitu.invalid') <> 'poistettu@anonymisoitu.invalid'
          or g.greeting is not null or g.cover_message is not null or g.note is not null) as has_pii
    from booking.gift_cards g left join booking.orders o on o.id = g.purchase_order_id cross join p
),
-- Asiakkaan viimeisin tapahtuma: tilaukset (varaukset, maksut, palautukset, laskut, kuitit), laskut, lahjakortit (osto, käyttö, voimassaolo),
-- vuosikortit (voimassaolo, peruutus), jonotus ja yritystarjous samalla sähköpostilla.
cust_ev as (
  select u.cid, max(u.at) as latest from (
    select c.id as cid, c.created_at as at from booking.customers c
    union all select ord.customer_id, ord.latest from ord where ord.customer_id is not null
    union all select ic.customer_id, greatest(i.created_at, i.invoice_date::timestamp at time zone 'Europe/Helsinki', i.paid_at, i.voided_at, i.sent_at)
                from booking.invoices i join booking.invoice_customers ic on ic.id = i.customer_id where ic.customer_id is not null
    union all select gc.cid, gc.latest from gc where gc.cid is not null
    union all select a.customer_id, greatest(a.created_at, (a.valid_to + 1)::timestamp at time zone 'Europe/Helsinki', a.revoked_at) from booking.annual_cards a
    union all select c.id, greatest(w.created_at, w.updated_at, w.ends_at) from booking.waitlist_entries w join booking.customers c on lower(c.email) = lower(w.customer_email)
    union all select c.id, greatest(b.created_at, b.handled_at) from booking.business_quote_requests b join booking.customers c on lower(c.email) = lower(b.email)
  ) u group by u.cid
),
cust as (
  select c.id, c.anonymized_at,
         case when exists (select 1 from ord where ord.customer_id = c.id and ord.blocked = 'future_reservation') then 'future_reservation'
              when exists (select 1 from gc where gc.cid = c.id and gc.is_active) then 'active_gift_card'
              when exists (select 1 from booking.annual_cards a where a.customer_id = c.id and a.active and a.revoked_at is null and a.valid_to >= p.as_of) then 'active_annual_card'
              when exists (select 1 from ord where ord.customer_id = c.id and ord.blocked is not null)
                then (select min(ord.blocked) from ord where ord.customer_id = c.id)
              when exists (select 1 from gc where gc.cid = c.id and gc.is_pending) then 'open_payment'
              when exists (select 1 from booking.invoices i join booking.invoice_customers ic on ic.id = i.customer_id
                            where ic.customer_id = c.id and i.status in ('draft', 'sent', 'overdue')) then 'open_invoice'
              when exists (select 1 from booking.waitlist_entries w where lower(w.customer_email) = lower(c.email) and w.status in ('waiting', 'notified')) then 'open_waitlist'
              when c.marketing_consent and c.marketing_unsubscribed_at is null then 'marketing_consent' end as blocked
    from booking.customers c join cust_ev e on e.cid = c.id cross join p
   where e.latest < p.cut3
),
-- 3 v: tilaukset, joiden asiakas on erääntynyt, sekä asiakkaattomat tilaukset omien päiviensä mukaan.
ord3 as (
  select ord.id, case when ord.customer_id is null then ord.blocked else cust.blocked end as blocked
    from ord cross join p left join cust on cust.id = ord.customer_id
   where (ord.customer_id is not null and cust.id is not null) or (ord.customer_id is null and ord.latest < p.cut3)
),
-- 6 v: tilaukset, joiden kirjanpitovuoden säilytys on päättynyt.
ord6 as (
  select ord.id, ord.blocked from ord cross join p
   where ord.acct_day is not null
     and extract(year from ord.acct_day)::integer + case when to_char(ord.acct_day, 'MM-DD') <= p.fye then 0 else 1 end <= p.max_acct_year
),
inv6 as (
  select i.id from booking.invoices i cross join p
   cross join lateral (select (greatest(i.created_at, i.invoice_date::timestamp at time zone 'Europe/Helsinki', i.paid_at, i.voided_at, i.sent_at)
                                at time zone 'Europe/Helsinki')::date as d) x
   where i.status not in ('draft', 'sent', 'overdue')
     and (i.order_id in (select ord6.id from ord6 where ord6.blocked is null)
          or (i.order_id is null
              and extract(year from x.d)::integer + case when to_char(x.d, 'MM-DD') <= p.fye then 0 else 1 end <= p.max_acct_year))
     and not exists (select 1 from ord where ord.id = i.order_id and ord.blocked is not null)
),
cand as (
  select 'customers'::text as category, cust.id, cust.blocked from cust where cust.anonymized_at is null
  union all
  select 'orders_3y', o.id, ord3.blocked from ord3 join booking.orders o on o.id = ord3.id
   where o.customer_note is not null or o.internal_note is not null
      or (jsonb_typeof(o.billing) = 'object' and o.billing ?| array['email', 'phone'])
  union all
  select 'reservations_3y', r.id, null from booking.reservations r join ord3 on ord3.id = r.order_id and ord3.blocked is null cross join p
   where r.status <> 'pending' and r.ends_at < p.as_of_ts
     and (r.notes is not null or r.cancel_reason is not null or r.therapist_exception_note is not null or r.override_reason is not null or r.hidden_reason is not null)
  union all
  select 'order_requests_3y', q.id, null from booking.order_requests q join ord3 on ord3.id = q.order_id and ord3.blocked is null
   where q.status <> 'open' and (q.reason is not null or q.note is not null or q.payload is not null)
  union all
  select 'voucher_claims_3y', v.id, null from booking.voucher_claims v join ord3 on ord3.id = v.order_id and ord3.blocked is null
   where v.status not in ('open', 'processing')
     and (v.customer_name is not null or v.customer_email is not null or v.customer_phone is not null or v.notes is not null)
  union all
  select 'gift_cards_3y', gc.id, case when gc.is_active then 'active_gift_card' when gc.is_pending then 'open_payment' end
    from gc cross join p where gc.latest < p.cut3 and gc.has_pii
  union all
  select 'annual_cards_3y', a.id, case when a.active and a.revoked_at is null and a.valid_to >= p.as_of then 'active_annual_card' end
    from booking.annual_cards a cross join p
   where a.notes is not null and greatest(a.created_at, (a.valid_to + 1)::timestamp at time zone 'Europe/Helsinki', a.revoked_at) < p.cut3
  union all
  select 'waitlist_3y', w.id, case when w.status in ('waiting', 'notified') then 'open_waitlist' end
    from booking.waitlist_entries w cross join p
   where w.customer_email <> 'poistettu@anonymisoitu.invalid' and greatest(w.created_at, w.updated_at, w.ends_at) < p.cut3
  union all
  select 'quotes_3y', b.id, null from booking.business_quote_requests b cross join p
   where b.email <> 'poistettu@anonymisoitu.invalid' and greatest(b.created_at, b.handled_at) < p.cut3
  union all
  select 'campaign_sends_3y', s.id, null from booking.campaign_sends s cross join p
   where s.email <> 'poistettu@anonymisoitu.invalid' and s.status <> 'queued'
     and (s.queued_at < p.cut3 or s.customer_id in (select cust.id from cust where cust.blocked is null))
  union all
  select 'orders_6y', o.id, ord6.blocked from ord6 join booking.orders o on o.id = ord6.id
   where o.billing is not null or o.invoice_reference is not null or o.customer_id is not null or o.customer_note is not null or o.internal_note is not null
  union all
  select 'payments_6y', y.id, null from booking.payments y join ord6 on ord6.id = y.order_id and ord6.blocked is null
   where y.status <> 'pending' and (y.raw is not null or y.note is not null or y.link_url is not null or y.link_token is not null)
  union all
  select 'refunds_6y', f.id, null from booking.refunds f join ord6 on ord6.id = f.order_id and ord6.blocked is null
   where f.status not in ('requested', 'processing') and (f.reason is not null or f.raw is not null)
  union all
  select 'receipts_6y', rc.id, null from booking.receipts rc join ord6 on ord6.id = rc.order_id and ord6.blocked is null
   where coalesce(rc.snapshot -> 'buyer', 'null'::jsonb) <> 'null'::jsonb or nullif(rc.snapshot ->> 'reason', '') is not null
  union all
  select 'invoices_6y', i.id, null from booking.invoices i join inv6 on inv6.id = i.id
   where i.customer_snapshot <> '{"anonymized": true}'::jsonb or i.notes is not null or i.buyer_reference is not null
  union all
  select 'invoice_dispatch_log_6y', d.id, null from booking.invoice_dispatch_log d join inv6 on inv6.id = d.invoice_id
   where d.payload <> '{"anonymized": true}'::jsonb
  union all
  select 'invoice_customers_6y', ic.id,
         case when exists (select 1 from booking.invoices i where i.customer_id = ic.id and i.status in ('draft', 'sent', 'overdue')) then 'open_invoice' end
    from booking.invoice_customers ic cross join p
   cross join lateral (select (greatest(ic.updated_at, (select max(greatest(i.created_at, i.invoice_date::timestamp at time zone 'Europe/Helsinki', i.paid_at, i.voided_at, i.sent_at))
                                                          from booking.invoices i where i.customer_id = ic.id)) at time zone 'Europe/Helsinki')::date as d) x
   where (ic.contact_name is not null or ic.email is not null or ic.phone is not null or ic.buyer_reference is not null)
     and extract(year from x.d)::integer + case when to_char(x.d, 'MM-DD') <= p.fye then 0 else 1 end <= p.max_acct_year
  union all
  select 'accounting_outbox_6y', a.id, null from booking.accounting_outbox a join ord6 on ord6.id = a.order_id and ord6.blocked is null
   where a.status in ('sent', 'dead', 'skipped') and a.payload <> '{"anonymized": true}'::jsonb
  union all
  select 'accounting_exports_6y', e.id, null from booking.accounting_exports e join inv6 on e.dedupe_key = 'invoice:' || inv6.id
   where e.kind = 'sales_invoice' and e.status in ('sent', 'skipped', 'dry_run') and (e.request is not null or e.response is not null)
  union all
  select 'gift_card_ledger_6y', l.id, null from booking.gift_card_ledger l cross join p
   cross join lateral (select (l.at at time zone 'Europe/Helsinki')::date as d) x
   where l.note is not null and extract(year from x.d)::integer + case when to_char(x.d, 'MM-DD') <= p.fye then 0 else 1 end <= p.max_acct_year
  union all
  select 'email_outbox', e.id, case when e.status in ('pending', 'sending') then 'open_email' end
    from booking.email_outbox e cross join p
   where e.created_at < p.cut_mail and e.payload <> '{"anonymized": true}'::jsonb
  union all
  select 'analytics_events', a.id, null from booking.analytics_events a cross join p where a.event_date < p.cut_analytics
),
-- audit_log: henkilöavaimet pois 3 v (asiakasrekisteri) / 6 v kirjanpitovuodesta (kirjanpitotaulut) tai kun rivin kohde käsitellään nyt.
pii(tbl, keys, acct) as (values
  ('customers', array['name', 'email', 'phone', 'company', 'address', 'zip', 'city', 'notes', 'business_id', 'einvoice_address', 'einvoice_operator', 'invoice_reference', 'auth_user_id'], false),
  ('reservations', array['notes', 'cancel_reason', 'therapist_exception_note', 'override_reason', 'hidden_reason'], false),
  ('order_requests', array['reason', 'note', 'payload'], false),
  ('voucher_claims', array['customer_name', 'customer_email', 'customer_phone', 'notes'], false),
  ('gift_cards', array['buyer_name', 'buyer_email', 'recipient_name', 'recipient_email', 'greeting', 'cover_message', 'note'], false),
  ('annual_cards', array['notes'], false),
  ('waitlist_entries', array['customer_name', 'customer_email', 'customer_phone'], false),
  ('business_quote_requests', array['company_name', 'contact_name', 'email', 'phone', 'message', 'admin_note', 'offering_other', 'preferred_when'], false),
  ('campaign_sends', array['email'], false),
  ('orders', array['customer_note', 'internal_note', 'billing', 'invoice_reference'], true),
  ('payments', array['raw', 'note', 'link_url'], true),
  ('refunds', array['reason', 'raw'], true),
  ('receipts', array['snapshot', 'text_body'], true),
  ('invoices', array['customer_snapshot', 'notes', 'buyer_reference'], true),
  ('invoice_customers', array['contact_name', 'email', 'phone', 'buyer_reference'], true),
  ('invoice_dispatch_log', array['payload'], true),
  ('accounting_exports', array['request', 'response'], true),
  ('gift_card_ledger', array['note'], true)
),
ent as (
  select 'customers'::text as tbl, c.id from cust c where c.blocked is null
  union all select 'orders', ord3.id from ord3 where ord3.blocked is null
  union all select 'orders', ord6.id from ord6 where ord6.blocked is null
  union all select case c.category when 'reservations_3y' then 'reservations' when 'order_requests_3y' then 'order_requests' when 'voucher_claims_3y' then 'voucher_claims'
                                   when 'gift_cards_3y' then 'gift_cards' when 'annual_cards_3y' then 'annual_cards' when 'waitlist_3y' then 'waitlist_entries'
                                   when 'quotes_3y' then 'business_quote_requests' when 'campaign_sends_3y' then 'campaign_sends' when 'payments_6y' then 'payments'
                                   when 'refunds_6y' then 'refunds' when 'receipts_6y' then 'receipts' when 'invoices_6y' then 'invoices'
                                   when 'invoice_customers_6y' then 'invoice_customers' when 'invoice_dispatch_log_6y' then 'invoice_dispatch_log'
                                   when 'accounting_exports_6y' then 'accounting_exports' when 'gift_card_ledger_6y' then 'gift_card_ledger' end, c.id
      from cand c where c.blocked is null and c.category not in ('customers', 'orders_3y', 'orders_6y', 'email_outbox', 'analytics_events', 'accounting_outbox_6y')
),
cand_all as (
  select c.category, c.id, c.blocked from cand c
  union all
  select 'audit_log', a.id, null from booking.audit_log a join pii on pii.tbl = a.table_name cross join p
   where (coalesce(a.old_data ?| pii.keys, false) or coalesce(a.new_data ?| pii.keys, false))
     and ((not pii.acct and a.at < p.cut3)
          or (pii.acct and extract(year from (a.at at time zone 'Europe/Helsinki')::date)::integer
                           + case when to_char((a.at at time zone 'Europe/Helsinki')::date, 'MM-DD') <= p.fye then 0 else 1 end <= p.max_acct_year)
          or exists (select 1 from ent where ent.tbl = a.table_name and ent.id::text = a.row_pk))
)
-- </privacy-candidates>
select cand_all.category, cand_all.id, cand_all.blocked from cand_all
$fn$;
revoke all on function booking._privacy_candidates(date) from public, anon, authenticated;
grant execute on function booking._privacy_candidates(date) to service_role;

-- kb.leads (yhteydenotot/tarjouspyynnöt kb-skeemassa) vain jos taulu on olemassa.
create or replace function booking._privacy_kb_leads(p_as_of date)
returns table(id bigint, blocked text) language plpgsql stable security definer set search_path = '' as $$
begin
  if to_regclass('kb.leads') is null then return; end if;
  return query execute $q$
    select l.id, case when l.marketing_consent then 'marketing_consent' end
      from kb.leads l
     where greatest(l.created_at, l.updated_at) < (($1 - make_interval(years => $2))::timestamp at time zone 'Europe/Helsinki')
       and (l.name is not null or l.email is not null or l.phone is not null or l.message is not null
            or l.handled_note is not null or l.quiz_answers is not null or l.session_hash is not null) $q$
  using p_as_of, booking._privacy_int('privacy_retention.customer_years', 3, 1, 50);
end $$;
revoke all on function booking._privacy_kb_leads(date) from public, anon, authenticated;
grant execute on function booking._privacy_kb_leads(date) to service_role;

-- ===== kuivaharjoitus: määrät + esimerkki-id:t, ei kirjoituksia =====
create or replace function booking.privacy_retention_report(p_as_of date default (now() at time zone 'Europe/Helsinki')::date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_as_of date := coalesce(p_as_of, (now() at time zone 'Europe/Helsinki')::date); r jsonb;
begin
  perform booking._privacy_require_admin();
  with c as (
    select x.category, x.id, x.blocked from booking._privacy_candidates(v_as_of) x
    union all select 'kb_leads_3y', l.id, l.blocked from booking._privacy_kb_leads(v_as_of) l
  ), cats as (
    select c.category,
           count(*) filter (where c.blocked is null)::int as due,
           coalesce((select jsonb_object_agg(b.blocked, b.n) from (select c2.blocked, count(*)::int n from c c2
                       where c2.category = c.category and c2.blocked is not null group by c2.blocked) b), '{}'::jsonb) as blocked,
           coalesce((select jsonb_agg(s.id order by s.id) from (select c3.id from c c3 where c3.category = c.category and c3.blocked is null
                       order by c3.id limit 5) s), '[]'::jsonb) as sample_ids
      from c group by c.category
  )
  select jsonb_build_object(
    'as_of', v_as_of,
    'dry_run', true,
    'enabled', coalesce((select s.value = 'true'::jsonb from booking.settings s where s.key = 'privacy_retention.enabled'), false),
    'settings', jsonb_build_object(
       'customer_years', booking._privacy_int('privacy_retention.customer_years', 3, 1, 50),
       'accounting_years', booking._privacy_int('privacy_retention.accounting_years', 6, 1, 50),
       'fiscal_year_end', booking._privacy_fy_end_mmdd(),
       'email_outbox_months', booking._privacy_int('privacy_retention.email_outbox_months', 12, 1, 600),
       'analytics_retention_months', booking._privacy_int('analytics_retention_months', 13, 1, 9999)),
    'categories', coalesce((select jsonb_object_agg(cats.category, jsonb_build_object('due', cats.due, 'blocked', cats.blocked, 'sample_ids', cats.sample_ids)) from cats), '{}'::jsonb))
  into r;
  return r;
end $$;
revoke all on function booking.privacy_retention_report(date) from public, anon;
grant execute on function booking.privacy_retention_report(date) to authenticated, service_role;

-- ===== ajo =====
create or replace function booking.privacy_retention_run()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_as_of date := (now() at time zone 'Europe/Helsinki')::date;
  v_cut3 timestamptz;
  v_enabled boolean;
  v_counts jsonb := '{}'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_n integer; v_m integer; v_run bigint; v_audit_start bigint; v_ids bigint[];
begin
  perform booking._privacy_require_admin();
  v_enabled := coalesce((select s.value = 'true'::jsonb from booking.settings s where s.key = 'privacy_retention.enabled'), false);
  if not v_enabled then
    insert into booking.privacy_retention_runs(as_of, enabled, actor, actor_role, status, finished_at)
    values (v_as_of, false, auth.uid(), booking._jwt_role(), 'disabled', now()) returning id into v_run;
    return jsonb_build_object('ok', true, 'enabled', false, 'run_id', v_run, 'counts', '{}'::jsonb);
  end if;
  v_cut3 := (v_as_of - make_interval(years => booking._privacy_int('privacy_retention.customer_years', 3, 1, 50)))::timestamp at time zone 'Europe/Helsinki';
  v_audit_start := coalesce((select max(a.id) from booking.audit_log a), 0);
  perform set_config('booking.privacy_retention', 'on', true);
  perform set_config('booking.allow_ledger_rewrite', '1', true);
  drop table if exists pg_temp._privacy_cand;
  create temp table _privacy_cand on commit drop as
    select c.category, c.id from booking._privacy_candidates(v_as_of) c where c.blocked is null and c.category <> 'analytics_events';
  create index on pg_temp._privacy_cand (category, id);

  -- --- 3 v: asiakasrekisteri ---
  begin
    update booking.customers c
       set name = 'Anonymisoitu asiakas', email = null, phone = null, address = null, zip = null, city = null, notes = null,
           company = case when c.customer_kind = 'company' then c.company end,
           business_id = case when c.customer_kind = 'company' then c.business_id end,
           einvoice_address = null, einvoice_operator = null, invoice_reference = null, auth_user_id = null,
           marketing_consent = false, unsubscribe_token = gen_random_uuid(), anonymized_at = now()
     where c.id in (select x.id from pg_temp._privacy_cand x where x.category = 'customers')
       and c.anonymized_at is null
       -- tarkistus vielä päivitettäessä: ei uusia tilauksia eikä aktiivisia kortteja
       and not exists (select 1 from booking.orders o where o.customer_id = c.id and o.created_at >= v_cut3)
       and not exists (select 1 from booking.annual_cards a where a.customer_id = c.id and a.active and a.revoked_at is null and a.valid_to >= v_as_of);
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('customers', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'customers', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.orders o
       set customer_note = null, internal_note = null,
           billing = case when jsonb_typeof(o.billing) = 'object' then o.billing - array['email', 'phone'] else o.billing end
     where o.id in (select x.id from pg_temp._privacy_cand x where x.category = 'orders_3y');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('orders_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'orders_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.reservations r
       set notes = null, cancel_reason = null, therapist_exception_note = null, override_reason = null, hidden_reason = null
     where r.id in (select x.id from pg_temp._privacy_cand x where x.category = 'reservations_3y')
       and r.status <> 'pending' and r.ends_at < now();
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('reservations_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'reservations_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.order_requests q set reason = null, note = null, payload = null
     where q.id in (select x.id from pg_temp._privacy_cand x where x.category = 'order_requests_3y') and q.status <> 'open';
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('order_requests_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'order_requests_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.voucher_claims v set customer_name = null, customer_email = null, customer_phone = null, notes = null
     where v.id in (select x.id from pg_temp._privacy_cand x where x.category = 'voucher_claims_3y') and v.status not in ('open', 'processing');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('voucher_claims_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'voucher_claims_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.gift_cards g
       set buyer_name = null, buyer_email = null, recipient_name = null,
           recipient_email = case when g.delivery_to = 'recipient' then 'poistettu@anonymisoitu.invalid' end,
           greeting = null, cover_message = null, note = null
     where g.id in (select x.id from pg_temp._privacy_cand x where x.category = 'gift_cards_3y')
       and not (g.status = 'active' and g.balance > 0 and (g.valid_to is null or g.valid_to >= v_as_of))
       and g.status not in ('pending_verification', 'pending_payment');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('gift_cards_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'gift_cards_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.annual_cards a set notes = null
     where a.id in (select x.id from pg_temp._privacy_cand x where x.category = 'annual_cards_3y')
       and not (a.active and a.revoked_at is null and a.valid_to >= v_as_of);
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('annual_cards_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'annual_cards_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.waitlist_entries w
       set customer_name = 'Anonymisoitu', customer_email = 'poistettu@anonymisoitu.invalid', customer_phone = null, whatsapp_opt_in = false
     where w.id in (select x.id from pg_temp._privacy_cand x where x.category = 'waitlist_3y') and w.status not in ('waiting', 'notified');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('waitlist_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'waitlist_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.business_quote_requests b
       set company_name = 'Anonymisoitu', contact_name = 'Anonymisoitu', email = 'poistettu@anonymisoitu.invalid', phone = '000000',
           preferred_when = 'poistettu', message = null, admin_note = null,
           offering_other = case when b.offering_other is not null then 'muu' end
     where b.id in (select x.id from pg_temp._privacy_cand x where x.category = 'quotes_3y');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('quotes_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'quotes_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.campaign_sends s set email = 'poistettu@anonymisoitu.invalid', error = null
     where s.id in (select x.id from pg_temp._privacy_cand x where x.category = 'campaign_sends_3y') and s.status <> 'queued';
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('campaign_sends_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'campaign_sends_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    v_n := 0;
    if to_regclass('kb.leads') is not null then
      select coalesce(array_agg(l.id), '{}') into v_ids from booking._privacy_kb_leads(v_as_of) l where l.blocked is null;
      execute 'update kb.leads set name = null, email = null, phone = null, message = null, handled_note = null, quiz_answers = null, session_hash = null
                where id = any($1)' using v_ids;
      get diagnostics v_n = row_count;
    end if;
    v_counts := v_counts || jsonb_build_object('kb_leads_3y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'kb_leads_3y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;

  -- --- 6 v: kirjanpitoaineisto (summat, päivät, tuotteet ja maksutavat säilyvät) ---
  begin
    update booking.orders o set billing = null, invoice_reference = null, customer_note = null, internal_note = null, customer_id = null
     where o.id in (select x.id from pg_temp._privacy_cand x where x.category = 'orders_6y');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('orders_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'orders_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.payments y set raw = null, note = null, link_url = null, link_token = null
     where y.id in (select x.id from pg_temp._privacy_cand x where x.category = 'payments_6y') and y.status <> 'pending';
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('payments_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'payments_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.refunds f set reason = null, raw = null
     where f.id in (select x.id from pg_temp._privacy_cand x where x.category = 'refunds_6y') and f.status not in ('requested', 'processing');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('refunds_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'refunds_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.receipts r set snapshot = z.s, text_body = booking._receipt_text(z.s)
      from (select r2.id, r2.snapshot || '{"buyer": null}'::jsonb
                   || case when r2.snapshot ? 'reason' then '{"reason": null}'::jsonb else '{}'::jsonb end as s
              from booking.receipts r2
             where r2.id in (select x.id from pg_temp._privacy_cand x where x.category = 'receipts_6y')) z
     where r.id = z.id;
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('receipts_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'receipts_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.invoices i set customer_snapshot = '{"anonymized": true}'::jsonb, notes = null, buyer_reference = null
     where i.id in (select x.id from pg_temp._privacy_cand x where x.category = 'invoices_6y') and i.status not in ('draft', 'sent', 'overdue');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('invoices_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'invoices_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.invoice_dispatch_log d set payload = '{"anonymized": true}'::jsonb
     where d.id in (select x.id from pg_temp._privacy_cand x where x.category = 'invoice_dispatch_log_6y');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('invoice_dispatch_log_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'invoice_dispatch_log_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.invoice_customers ic
       -- yrityksen tunnistetiedot (nimi, Y-tunnus, ALV-tunnus, osoite, verkkolaskuosoite) ovat yritys- eivätkä henkilötietoja: säilyvät
       set contact_name = null, email = null, phone = null, buyer_reference = null
     where ic.id in (select x.id from pg_temp._privacy_cand x where x.category = 'invoice_customers_6y');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('invoice_customers_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'invoice_customers_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.accounting_outbox a set payload = '{"anonymized": true}'::jsonb
     where a.id in (select x.id from pg_temp._privacy_cand x where x.category = 'accounting_outbox_6y') and a.status in ('sent', 'dead', 'skipped');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('accounting_outbox_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'accounting_outbox_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.accounting_exports e set request = null, response = null
     where e.id in (select x.id from pg_temp._privacy_cand x where x.category = 'accounting_exports_6y') and e.status in ('sent', 'skipped', 'dry_run');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('accounting_exports_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'accounting_exports_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;
  begin
    update booking.gift_card_ledger l set note = null
     where l.id in (select x.id from pg_temp._privacy_cand x where x.category = 'gift_card_ledger_6y');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('gift_card_ledger_6y', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'gift_card_ledger_6y', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;

  -- --- sähköpostijono: vain päättyneet rivit ---
  begin
    update booking.email_outbox e
       set payload = '{"anonymized": true}'::jsonb,
           last_error = regexp_replace(e.last_error, '[^[:space:]<>"'',;:]+@[^[:space:]<>"'',;:]+', '[poistettu]', 'g')
     where e.id in (select x.id from pg_temp._privacy_cand x where x.category = 'email_outbox') and e.status not in ('pending', 'sending');
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('email_outbox', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'email_outbox', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;

  -- --- audit_log: vanhat rivit + tämän ajon käsittelemien kohteiden rivit (myös ajon itse synnyttämät) ---
  begin
    update booking.audit_log a
       set old_data = case when a.old_data ?| k.keys then (a.old_data - k.keys) || '{"_pii_removed": true}'::jsonb else a.old_data end,
           new_data = case when a.new_data ?| k.keys then (a.new_data - k.keys) || '{"_pii_removed": true}'::jsonb else a.new_data end
      from booking._privacy_pii_keys() k
     where k.tbl = a.table_name
       and (coalesce(a.old_data ?| k.keys, false) or coalesce(a.new_data ?| k.keys, false))
       and (a.id in (select x.id from pg_temp._privacy_cand x where x.category = 'audit_log')
            or (a.id > v_audit_start
                and exists (select 1 from pg_temp._privacy_cand x where x.category = any(k.cats) and x.id::text = a.row_pk)));
    get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('audit_log', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('category', 'audit_log', 'error', sqlstate || ' ' || left(sqlerrm, 200));
  end;

  perform set_config('booking.privacy_retention', '', true);
  perform set_config('booking.allow_ledger_rewrite', '', true);
  insert into booking.privacy_retention_runs(as_of, enabled, actor, actor_role, status, counts, errors, finished_at)
  values (v_as_of, true, auth.uid(), booking._jwt_role(), case when jsonb_array_length(v_errors) = 0 then 'ok' else 'partial' end, v_counts, v_errors, now())
  returning id into v_run;
  return jsonb_build_object('ok', jsonb_array_length(v_errors) = 0, 'enabled', true, 'run_id', v_run, 'as_of', v_as_of, 'counts', v_counts, 'errors', v_errors);
end $$;
revoke all on function booking.privacy_retention_run() from public, anon;
grant execute on function booking.privacy_retention_run() to authenticated, service_role;

-- ===== kävijämittaus: k-anonymiteetti kuukausikoosteeseen =====
create or replace function booking._analytics_monthly_kanon()
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare v_k integer := booking._privacy_int('analytics_k_min', 5, 1, 1000); v_n integer; v_m integer;
begin
  -- 1) pieni ryhmä → polku '/muu' (muut ulottuvuudet ennallaan)
  with s as (
    delete from booking.analytics_monthly m where m.kind = 'event' and m.events < v_k and m.path <> '/muu' returning m.*
  )
  insert into booking.analytics_monthly as t (month, kind, event_type, path, locale, device_type, source_category, product_id,
                                              events, checkouts, purchases, orders, amount_gross_sum)
  select s.month, s.kind, s.event_type, '/muu', s.locale, s.device_type, s.source_category, s.product_id,
         sum(s.events), sum(s.checkouts), sum(s.purchases), sum(s.orders), sum(s.amount_gross_sum)
    from s group by s.month, s.kind, s.event_type, s.locale, s.device_type, s.source_category, s.product_id
  on conflict (month, kind, event_type, path, locale, device_type, source_category, product_id) do update
     set events = t.events + excluded.events, checkouts = t.checkouts + excluded.checkouts, purchases = t.purchases + excluded.purchases,
         orders = t.orders + excluded.orders, amount_gross_sum = t.amount_gross_sum + excluded.amount_gross_sum, updated_at = now();
  get diagnostics v_n = row_count;
  -- 2) yhä pieni → kieli/laite/lähde 'muu', tuote -1 (event) / yleinen käyntirivi (visit). Tapahtumatyyppi säilyy.
  with s as (
    delete from booking.analytics_monthly m
     where m.kind in ('event', 'visit') and m.events < v_k
       and not (m.locale = 'muu' and m.device_type = 'muu' and m.source_category = 'muu'
                and (m.kind = 'visit' or (m.path = '/muu' and m.product_id = -1)))
    returning m.*
  )
  insert into booking.analytics_monthly as t (month, kind, event_type, path, locale, device_type, source_category, product_id,
                                              events, checkouts, purchases, orders, amount_gross_sum)
  select s.month, s.kind, s.event_type, case when s.kind = 'event' then '/muu' else '*' end, 'muu', 'muu', 'muu',
         case when s.kind = 'event' then -1 else 0 end,
         sum(s.events), sum(s.checkouts), sum(s.purchases), sum(s.orders), sum(s.amount_gross_sum)
    from s group by 1, 2, 3, 4, 8
  on conflict (month, kind, event_type, path, locale, device_type, source_category, product_id) do update
     set events = t.events + excluded.events, checkouts = t.checkouts + excluded.checkouts, purchases = t.purchases + excluded.purchases,
         orders = t.orders + excluded.orders, amount_gross_sum = t.amount_gross_sum + excluded.amount_gross_sum, updated_at = now();
  get diagnostics v_m = row_count;
  return v_n + v_m;
end $$;
revoke all on function booking._analytics_monthly_kanon() from public, anon, authenticated;
grant execute on function booking._analytics_monthly_kanon() to service_role;

-- Säilytysajan siivous (pg_cron). Palauttaa poistettujen tapahtumien määrän (kuten booking_150).
-- booking_157: poistettavat rivit koostetaan samassa lauseessa (delete ... returning) kuukausikoosteeseen ennen poistoa.
create or replace function booking.analytics_cleanup()
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  v_months integer;
  v_n integer;
  v_cut date;
begin
  begin
    v_months := (booking._setting('analytics_retention_months', '13'::jsonb) #>> '{}')::integer;
  exception when others then v_months := 13;
  end;
  if v_months is null or v_months < 1 then v_months := 13; end if;
  v_cut := ((now() at time zone 'Europe/Helsinki')::date - make_interval(months => v_months))::date;
  with del as (
    delete from booking.analytics_events where event_date < v_cut returning *
  ), d as (
    select del.*, date_trunc('month', del.event_date)::date as month,
           coalesce(del.product_id, (select k.id from kb.products k where k.slug = del.product_slug order by k.id limit 1),
                    case when del.product_slug is not null then -1 else 0 end) as pid
      from del
  ), ev as (
    insert into booking.analytics_monthly as t (month, kind, event_type, path, locale, device_type, source_category, product_id, events, amount_gross_sum)
    select d.month, 'event', d.event_type, d.path, d.locale, d.device_type, d.source_category, d.pid, count(*), coalesce(sum(d.amount_gross), 0)
      from d group by d.month, d.event_type, d.path, d.locale, d.device_type, d.source_category, d.pid
    on conflict (month, kind, event_type, path, locale, device_type, source_category, product_id) do update
       set events = t.events + excluded.events, amount_gross_sum = t.amount_gross_sum + excluded.amount_gross_sum, updated_at = now()
    returning 1
  ), vis as (
    select distinct on (d.event_date, d.session_key) d.event_date, d.session_key, d.month, d.source_category, d.device_type, d.locale
      from d where d.event_type = 'page_view' order by d.event_date, d.session_key, d.created_at, d.id
  ), ses as (
    select d.event_date, d.session_key, bool_or(d.event_type = 'checkout_start') as co, bool_or(d.event_type = 'purchase') as pu
      from d group by d.event_date, d.session_key
  ), vi as (
    insert into booking.analytics_monthly as t (month, kind, event_type, path, locale, device_type, source_category, product_id, events, checkouts, purchases)
    select v.month, 'visit', 'page_view', '*', v.locale, v.device_type, v.source_category, 0,
           count(*), count(*) filter (where s.co), count(*) filter (where s.pu)
      from vis v join ses s on s.event_date = v.event_date and s.session_key = v.session_key
     group by v.month, v.locale, v.device_type, v.source_category
    on conflict (month, kind, event_type, path, locale, device_type, source_category, product_id) do update
       set events = t.events + excluded.events, checkouts = t.checkouts + excluded.checkouts, purchases = t.purchases + excluded.purchases, updated_at = now()
    returning 1
  ), uq as (
    select z.month, z.event_type, sum(z.n) as n
      from (select d.month, d.event_date, d.event_type, count(distinct d.session_key) as n from d group by d.month, d.event_date, d.event_type) z
     group by z.month, z.event_type
  ), po as (
    select z.month, count(*) as orders, coalesce(sum(z.amount_gross), 0) as gross
      from (select distinct on (d.order_id) d.month, d.order_id, d.amount_gross from d
             where d.event_type = 'purchase' and d.order_id is not null order by d.order_id, d.created_at desc) z
     group by z.month
  ), un as (
    insert into booking.analytics_monthly as t (month, kind, event_type, path, locale, device_type, source_category, product_id, events, orders, amount_gross_sum)
    select uq.month, 'unique', uq.event_type, '*', '*', '*', '*', 0, uq.n,
           case when uq.event_type = 'purchase' then coalesce(po.orders, 0) else 0 end,
           case when uq.event_type = 'purchase' then coalesce(po.gross, 0) else 0 end
      from uq left join po on po.month = uq.month
    on conflict (month, kind, event_type, path, locale, device_type, source_category, product_id) do update
       set events = t.events + excluded.events, orders = t.orders + excluded.orders,
           amount_gross_sum = t.amount_gross_sum + excluded.amount_gross_sum, updated_at = now()
    returning 1
  )
  select count(*) into v_n from del;
  if v_n > 0 then perform booking._analytics_monthly_kanon(); end if;
  delete from booking.analytics_daily_counts where event_date < (now() at time zone 'Europe/Helsinki')::date - 2;
  return v_n;
end $$;
revoke all on function booking.analytics_cleanup() from public, anon, authenticated;
grant execute on function booking.analytics_cleanup() to service_role;

-- ===== raportti: raakadata + kuukausikooste =====
create or replace function booking.admin_analytics_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; v_today date := (now() at time zone 'Europe/Helsinki')::date;
begin
  perform booking._require_staff();
  if not (booking.has_permission('reports.view') or booking.has_permission('reports.daily')) then
    perform booking._err('forbidden','Raporttien tarkasteluoikeus puuttuu');
  end if;
  -- booking_157: menneisyyteen osuva pitkä aikaväli luetaan kuukausikoosteesta (enintään 3661 päivää); muuten enintään 367 päivää.
  if p_from is null or p_to is null or p_from > p_to or (p_to - p_from > 366 and (p_to > v_today or p_to - p_from > 3660)) then
    perform booking._err('invalid_range','Aikaväli saa olla enintään 367 päivää (menneisyydessä enintään 3661 päivää)');
  end if;
  if not exists (select 1 from booking.analytics_monthly m where m.month between date_trunc('month', p_from)::date and p_to) then
    -- Ei koostekuukausia: täsmälleen booking_150:n kysely.
    with e as materialized (
      select * from booking.analytics_events where event_date between p_from and p_to
    ), f as (
      select count(distinct session_key) filter(where event_type='page_view')::int visitors,
             count(distinct session_key) filter(where event_type='product_view')::int product_viewers,
             count(distinct session_key) filter(where event_type='checkout_start')::int checkout_starters,
             count(distinct session_key) filter(where event_type='purchase')::int buyers,
             count(*) filter(where event_type='page_view')::int page_view_events,
             count(*) filter(where event_type='product_view')::int product_view_events,
             count(*) filter(where event_type='checkout_start')::int checkout_events,
             count(*) filter(where event_type='purchase')::int purchase_events
      from e
    ), paid as (
      select count(*)::int orders,coalesce(sum(amount_gross),0)::numeric(12,2) gross from
         (select distinct on(order_id) order_id,amount_gross from e where event_type='purchase' and order_id is not null order by order_id,created_at desc) p
    ), visits as (
      select distinct on (session_key) session_key,source_category,utm_campaign,referrer_domain,device_type,locale
         from e where event_type='page_view' order by session_key,created_at,id
    ), buyer_sessions as (
      select distinct session_key from e where event_type='purchase'
    ), checkout_sessions as (
      select distinct session_key from e where event_type='checkout_start'
    ), sources as (
      select v.source_category, count(*)::int visits,
             count(c.session_key)::int checkouts,count(b.session_key)::int purchases,
             round(100.0*count(b.session_key)/nullif(count(*),0),2) conversion_pct
         from visits v left join checkout_sessions c using(session_key) left join buyer_sessions b using(session_key)
         group by v.source_category
    ), top_campaign as (
       select source_category,utm_campaign,count(*)::int n from visits where utm_campaign is not null group by 1,2
    ), top_ref as (
       select source_category,referrer_domain,count(*)::int n from visits where referrer_domain is not null group by 1,2
    ), products as (
      select coalesce(e.product_id,-1) product_id,e.product_slug,
        count(*) filter (where e.event_type='product_view')::int views,
        count(*) filter (where e.event_type='checkout_start')::int checkouts,
        count(*) filter (where e.event_type='purchase')::int purchases
      from e where e.product_id is not null or e.product_slug is not null group by coalesce(e.product_id,-1),e.product_slug
    ), devices as (
       select device_type,count(*)::int visits,count(b.session_key)::int purchases from visits v left join buyer_sessions b using(session_key) group by device_type
    ), locales as (
       select locale,count(*)::int visits,count(b.session_key)::int purchases from visits v left join buyer_sessions b using(session_key) group by locale
    ), days as (
       select d::date as d_day from generate_series(p_from,p_to,interval '1 day') d
    ), daily as (
       -- booking_150: yksi kooste päivittäin (GROUP BY), ei päiväkohtaisia alikyselyitä. Indeksi analytics_events_date_type_session_idx.
       select a.event_date,
              count(distinct a.session_key) filter (where a.event_type='page_view') visitors,
              count(*) filter (where a.event_type='product_view') product_views,
              count(*) filter (where a.event_type='checkout_start') checkouts,
              count(*) filter (where a.event_type='purchase') purchases
         from booking.analytics_events a
        where a.event_date between p_from and p_to
        group by a.event_date
    )
    select jsonb_build_object(
      'from',p_from,'to',p_to,
      'funnel', (select to_jsonb(f) || jsonb_build_object('paid_orders',paid.orders,'amount_gross',paid.gross,'conversion_pct',coalesce(round(100.0*f.buyers/nullif(f.visitors,0),2),0)) from f cross join paid),
      'sources',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object(
         'top_utm_campaign',(select t.utm_campaign from top_campaign t where t.source_category=s.source_category order by n desc,utm_campaign limit 1),
         'top_referrer_domain',(select t.referrer_domain from top_ref t where t.source_category=s.source_category order by n desc,referrer_domain limit 1)) order by s.visits desc) from sources s),'[]'::jsonb),
      'top_products',coalesce((select jsonb_agg(jsonb_build_object('product_id',nullif(p.product_id,-1),'product_slug',p.product_slug,'name',coalesce(k.name,p.product_slug,'Tuntematon tuote'),
        'views',p.views,'checkouts',p.checkouts,'purchases',p.purchases,
        'conversion_pct',coalesce(round(p.purchases*100.0/nullif(p.views,0),2),0)) order by p.views desc)
        from products p left join kb.products k on k.id=p.product_id or (p.product_id=-1 and k.slug=p.product_slug)),'[]'::jsonb),
      'devices_and_locales',jsonb_build_object(
         'devices',coalesce((select jsonb_agg(to_jsonb(d) order by visits desc) from devices d),'[]'::jsonb),
         'locales',coalesce((select jsonb_agg(to_jsonb(l) order by visits desc) from locales l),'[]'::jsonb)),
      'daily_series',coalesce((select jsonb_agg(jsonb_build_object('date',d.d_day,
         'visitors',coalesce(x.visitors,0),
         'product_views',coalesce(x.product_views,0),
         'checkouts',coalesce(x.checkouts,0),
         'purchases',coalesce(x.purchases,0)) order by d.d_day) from days d left join daily x on x.event_date=d.d_day),'[]'::jsonb)
    ) into result;
    return result;
  end if;
  -- Koostekuukausia mukana: raakadata (vielä säilytetyt päivät) + kooste (poistetut päivät). Jokainen tapahtuma on vain toisessa,
  -- joten tuplalaskentaa ei ole. Koostekuukausi sisältyy kokonaisena; uniikit istunnot ovat päiväkohtaisten summa.
  with e as materialized (
    select * from booking.analytics_events where event_date between p_from and p_to
  ), ag as materialized (
    select * from booking.analytics_monthly m where m.month between date_trunc('month', p_from)::date and p_to
  ), fr as (
    select count(distinct session_key) filter(where event_type='page_view')::int visitors,
           count(distinct session_key) filter(where event_type='product_view')::int product_viewers,
           count(distinct session_key) filter(where event_type='checkout_start')::int checkout_starters,
           count(distinct session_key) filter(where event_type='purchase')::int buyers,
           count(*) filter(where event_type='page_view')::int page_view_events,
           count(*) filter(where event_type='product_view')::int product_view_events,
           count(*) filter(where event_type='checkout_start')::int checkout_events,
           count(*) filter(where event_type='purchase')::int purchase_events
    from e
  ), fa as (
    select coalesce(sum(events) filter(where kind='unique' and event_type='page_view'),0)::int visitors,
           coalesce(sum(events) filter(where kind='unique' and event_type='product_view'),0)::int product_viewers,
           coalesce(sum(events) filter(where kind='unique' and event_type='checkout_start'),0)::int checkout_starters,
           coalesce(sum(events) filter(where kind='unique' and event_type='purchase'),0)::int buyers,
           coalesce(sum(events) filter(where kind='event' and event_type='page_view'),0)::int page_view_events,
           coalesce(sum(events) filter(where kind='event' and event_type='product_view'),0)::int product_view_events,
           coalesce(sum(events) filter(where kind='event' and event_type='checkout_start'),0)::int checkout_events,
           coalesce(sum(events) filter(where kind='event' and event_type='purchase'),0)::int purchase_events,
           coalesce(sum(orders) filter(where kind='unique' and event_type='purchase'),0)::int orders,
           coalesce(sum(amount_gross_sum) filter(where kind='unique' and event_type='purchase'),0)::numeric(12,2) gross
    from ag
  ), f as (
    select fr.visitors+fa.visitors visitors, fr.product_viewers+fa.product_viewers product_viewers,
           fr.checkout_starters+fa.checkout_starters checkout_starters, fr.buyers+fa.buyers buyers,
           fr.page_view_events+fa.page_view_events page_view_events, fr.product_view_events+fa.product_view_events product_view_events,
           fr.checkout_events+fa.checkout_events checkout_events, fr.purchase_events+fa.purchase_events purchase_events
    from fr cross join fa
  ), paid_raw as (
    select count(*)::int orders,coalesce(sum(amount_gross),0)::numeric(12,2) gross from
       (select distinct on(order_id) order_id,amount_gross from e where event_type='purchase' and order_id is not null order by order_id,created_at desc) p
  ), paid as (
    select paid_raw.orders+fa.orders orders, (paid_raw.gross+fa.gross)::numeric(12,2) gross from paid_raw cross join fa
  ), visits as (
    select distinct on (session_key) session_key,source_category,utm_campaign,referrer_domain,device_type,locale
       from e where event_type='page_view' order by session_key,created_at,id
  ), buyer_sessions as (
    select distinct session_key from e where event_type='purchase'
  ), checkout_sessions as (
    select distinct session_key from e where event_type='checkout_start'
  ), src_all as (
    select v.source_category, count(*) visits, count(c.session_key) checkouts, count(b.session_key) purchases
       from visits v left join checkout_sessions c using(session_key) left join buyer_sessions b using(session_key)
       group by v.source_category
    union all
    select source_category, sum(events), sum(checkouts), sum(purchases) from ag where kind='visit' group by source_category
  ), sources as (
    select source_category, sum(visits)::int visits, sum(checkouts)::int checkouts, sum(purchases)::int purchases,
           round(100.0*sum(purchases)/nullif(sum(visits),0),2) conversion_pct
      from src_all group by source_category
  ), top_campaign as (
     select source_category,utm_campaign,count(*)::int n from visits where utm_campaign is not null group by 1,2
  ), top_ref as (
     select source_category,referrer_domain,count(*)::int n from visits where referrer_domain is not null group by 1,2
  ), prod_all as (
    select coalesce(e.product_id,-1) product_id,e.product_slug,
      count(*) filter (where e.event_type='product_view') views,
      count(*) filter (where e.event_type='checkout_start') checkouts,
      count(*) filter (where e.event_type='purchase') purchases
    from e where e.product_id is not null or e.product_slug is not null group by coalesce(e.product_id,-1),e.product_slug
    union all
    select m.product_id, null::text,
      sum(m.events) filter (where m.event_type='product_view'),
      sum(m.events) filter (where m.event_type='checkout_start'),
      sum(m.events) filter (where m.event_type='purchase')
    from ag m where m.kind='event' and m.product_id <> 0 group by m.product_id
  ), products as (
    select min(product_id) product_id, max(product_slug) product_slug,
           coalesce(sum(views),0)::int views, coalesce(sum(checkouts),0)::int checkouts, coalesce(sum(purchases),0)::int purchases
      from prod_all
     group by case when product_id > 0 then product_id::text else 'slug:' || coalesce(product_slug, '') end
  ), dev_all as (
     select device_type,count(*) visits,count(b.session_key) purchases from visits v left join buyer_sessions b using(session_key) group by device_type
     union all select device_type, sum(events), sum(purchases) from ag where kind='visit' group by device_type
  ), devices as (
     select device_type, sum(visits)::int visits, sum(purchases)::int purchases from dev_all group by device_type
  ), loc_all as (
     select locale,count(*) visits,count(b.session_key) purchases from visits v left join buyer_sessions b using(session_key) group by locale
     union all select locale, sum(events), sum(purchases) from ag where kind='visit' group by locale
  ), locales as (
     select locale, sum(visits)::int visits, sum(purchases)::int purchases from loc_all group by locale
  ), days as (
     select d::date as d_day from generate_series(p_from,p_to,interval '1 day') d
  ), daily as (
     select a.event_date,
            count(distinct a.session_key) filter (where a.event_type='page_view') visitors,
            count(*) filter (where a.event_type='product_view') product_views,
            count(*) filter (where a.event_type='checkout_start') checkouts,
            count(*) filter (where a.event_type='purchase') purchases
       from booking.analytics_events a
      where a.event_date between p_from and p_to
      group by a.event_date
  ), months as (
     select m::date as m_month from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') m
  ), monthly as (
     select x.m, sum(x.visitors)::int visitors, sum(x.product_views)::int product_views, sum(x.checkouts)::int checkouts, sum(x.purchases)::int purchases
       from (select date_trunc('month', event_date)::date m, visitors, product_views, checkouts, purchases from daily
             union all
             select month,
                    coalesce(sum(events) filter (where kind='unique' and event_type='page_view'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='product_view'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='checkout_start'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='purchase'),0)
               from ag group by month) x
      group by x.m
  )
  select jsonb_build_object(
    'from',p_from,'to',p_to,
    'funnel', (select to_jsonb(f) || jsonb_build_object('paid_orders',paid.orders,'amount_gross',paid.gross,'conversion_pct',coalesce(round(100.0*f.buyers/nullif(f.visitors,0),2),0)) from f cross join paid),
    'sources',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object(
       'top_utm_campaign',(select t.utm_campaign from top_campaign t where t.source_category=s.source_category order by n desc,utm_campaign limit 1),
       'top_referrer_domain',(select t.referrer_domain from top_ref t where t.source_category=s.source_category order by n desc,referrer_domain limit 1)) order by s.visits desc) from sources s),'[]'::jsonb),
    'top_products',coalesce((select jsonb_agg(jsonb_build_object('product_id',nullif(p.product_id,-1),'product_slug',p.product_slug,
      'name',coalesce(k.name,p.product_slug,case when p.product_id=-1 then 'Muut tuotteet (kuukausikooste)' end,'Tuntematon tuote'),
      'views',p.views,'checkouts',p.checkouts,'purchases',p.purchases,
      'conversion_pct',coalesce(round(p.purchases*100.0/nullif(p.views,0),2),0)) order by p.views desc)
      from products p left join kb.products k on k.id=p.product_id or (p.product_id=-1 and k.slug=p.product_slug)),'[]'::jsonb),
    'devices_and_locales',jsonb_build_object(
       'devices',coalesce((select jsonb_agg(to_jsonb(d) order by visits desc) from devices d),'[]'::jsonb),
       'locales',coalesce((select jsonb_agg(to_jsonb(l) order by visits desc) from locales l),'[]'::jsonb)),
    'daily_series',coalesce((select jsonb_agg(jsonb_build_object('date',d.d_day,
       'visitors',coalesce(x.visitors,0),
       'product_views',coalesce(x.product_views,0),
       'checkouts',coalesce(x.checkouts,0),
       'purchases',coalesce(x.purchases,0)) order by d.d_day) from days d left join daily x on x.event_date=d.d_day),'[]'::jsonb),
    'monthly_series',coalesce((select jsonb_agg(jsonb_build_object('month',mo.m_month,
       'visitors',coalesce(y.visitors,0),'product_views',coalesce(y.product_views,0),
       'checkouts',coalesce(y.checkouts,0),'purchases',coalesce(y.purchases,0)) order by mo.m_month) from months mo left join monthly y on y.m=mo.m_month),'[]'::jsonb),
    'aggregated_months',coalesce((select jsonb_agg(z.m order by z.m) from (select distinct to_char(ag.month,'YYYY-MM') m from ag) z),'[]'::jsonb)
  ) into result;
  return result;
end $$;
revoke all on function booking.admin_analytics_summary(date,date) from public,anon;
grant execute on function booking.admin_analytics_summary(date,date) to authenticated,service_role;

-- ===== kirjanpitolukot: kapea tietosuojapoikkeus (muuten täsmälleen ennallaan) =====
create or replace function booking.receipts_guard_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then perform booking._err('receipt_immutable', 'Kuittia ei voi poistaa (säilytysvelvollisuus 6 v)'); end if;
  if (new.receipt_no, new.kind, new.series, new.year, new.seq, new.order_id, new.payment_id, new.refund_id, new.original_receipt_id, new.issued_at, new.total_gross, new.public_token)
     is distinct from
     (old.receipt_no, old.kind, old.series, old.year, old.seq, old.order_id, old.payment_id, old.refund_id, old.original_receipt_id, old.issued_at, old.total_gross, old.public_token) then
    perform booking._err('receipt_immutable', 'Kuittia ei voi muuttaa (vain pdf_path/pdf_generated_at/sent_at)');
  end if;
  if (new.snapshot, new.text_body) is distinct from (old.snapshot, old.text_body) then
    -- booking_157: ainoa poikkeus on tietosuoja-ajo (GUC booking.privacy_retention = 'on'), joka poistaa ostajan ja hyvityksen syyn
    -- kuitilta, jonka 6 v säilytysaika on päättynyt. Muu sisältö ja tekstikuitti (muodostetaan snapshotista) pysyvät.
    if coalesce(current_setting('booking.privacy_retention', true), '') <> 'on'
       or not booking._privacy_acct_due((old.issued_at at time zone 'Europe/Helsinki')::date)
       or coalesce(new.snapshot -> 'buyer', 'null'::jsonb) <> 'null'::jsonb
       or nullif(new.snapshot ->> 'reason', '') is not null
       or (new.snapshot - 'buyer' - 'reason') is distinct from (old.snapshot - 'buyer' - 'reason')
       or new.text_body is distinct from booking._receipt_text(new.snapshot) then
      perform booking._err('receipt_immutable', 'Kuittia ei voi muuttaa (vain pdf_path/pdf_generated_at/sent_at)');
    end if;
  end if;
  return new;
end $$;

create or replace function booking.invoices_lock_trg()
returns trigger language plpgsql set search_path = '' as $$
declare v_priv boolean := false;
begin
  if tg_op = 'DELETE' then
    perform booking._err('invoice_locked', 'Laskua ei poisteta. Mitätöi luonnos tai tee hyvityslasku.');
  end if;
  if old.status <> 'draft' then
    -- booking_157: tietosuoja-ajo saa tyhjentää asiakastiedot (customer_snapshot → {"anonymized": true}, notes, buyer_reference)
    -- vain päättyneeltä laskulta, jonka 6 v säilytysaika on päättynyt.
    if coalesce(current_setting('booking.privacy_retention', true), '') = 'on' and old.status in ('paid', 'credited', 'voided') then
      v_priv := booking._privacy_acct_due(greatest(old.invoice_date, (old.paid_at at time zone 'Europe/Helsinki')::date,
                                                   (old.voided_at at time zone 'Europe/Helsinki')::date, (old.sent_at at time zone 'Europe/Helsinki')::date))
                and new.customer_snapshot = '{"anonymized": true}'::jsonb and new.notes is null and new.buyer_reference is null;
    end if;
    if new.customer_id is distinct from old.customer_id
       or new.order_id is distinct from old.order_id
       or new.credit_of_id is distinct from old.credit_of_id
       or new.kind is distinct from old.kind
       or new.invoice_date is distinct from old.invoice_date
       or new.due_date is distinct from old.due_date
       or new.reference_no is distinct from old.reference_no
       or (not v_priv and new.buyer_reference is distinct from old.buyer_reference)
       or new.currency is distinct from old.currency
       or (not v_priv and new.notes is distinct from old.notes)
       or new.locale is distinct from old.locale
       or new.seller_snapshot is distinct from old.seller_snapshot
       or (not v_priv and new.customer_snapshot is distinct from old.customer_snapshot)
       or new.total_net is distinct from old.total_net
       or new.total_vat is distinct from old.total_vat
       or new.total_gross is distinct from old.total_gross
       or new.vat_breakdown is distinct from old.vat_breakdown
       or new.series is distinct from old.series
       or new.seq is distinct from old.seq
       or new.invoice_no is distinct from old.invoice_no
       or new.public_token is distinct from old.public_token
       or new.created_by is distinct from old.created_by
    then
      perform booking._err('invoice_locked', 'Lähetettyä laskua ei voi muokata. Tee hyvityslasku.');
    end if;
    if new.status is distinct from old.status and not (
         (old.status = 'sent' and new.status in ('paid', 'overdue', 'credited'))
         or (old.status = 'overdue' and new.status in ('paid', 'credited'))
         or (old.status = 'paid' and new.status = 'credited'))
    then
      perform booking._err('invalid_status', 'Laskun tilasiirtymä ei ole sallittu');
    end if;
  elsif new.status is distinct from old.status and new.status not in ('sent', 'voided') then
    perform booking._err('invalid_status', 'Luonnos voidaan lähettää tai mitätöidä');
  end if;
  return new;
end $$;

comment on function booking.privacy_retention_report(date) is 'booking_157: tietosuojan säilytysajat, kuivaharjoitus (vain luku): määrät ja esimerkki-id:t luokittain sekä estosyyt.';
comment on function booking.privacy_retention_run() is 'booking_157: tietosuojan säilytysajo. Vain admin/service_role/pg_cron. Ei tee mitään, ellei privacy_retention.enabled = true. Loki: booking.privacy_retention_runs.';
