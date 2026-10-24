-- ROLLBACK booking_160: tietosuojan säilytysajan korjaukset (migraatio 20261024330000).
-- Palauttaa kahdeksan uudelleenmääriteltyä funktiota TÄSMÄLLEEN tuotannon nykyiseen (booking_157 jälkeiseen) muotoon
-- (pg_get_functiondef-teksti sellaisenaan; CREATE OR REPLACE säilyttää oikeudet) ja tarkistaa lopuksi md5(pg_get_functiondef):n —
-- jos jokin ei täsmää, koko rollback perutaan. Poistaa booking_160:n uudet funktiot ja asetukset (dry_run, gift_card_pdf_years).
-- Sarakkeet pdf_deleted_at poistetaan vain, jos ne ovat tyhjiä; taulu booking.privacy_auth_deletions vain, jos se on tyhjä
-- (muuten jätetään, jotta tieto poistetuista PDF:istä/tileistä ei katoa). Ajoloki: status 'dry_run' -rivien vuoksi tarkistus NOT VALID.
-- HUOM: jo anonymisoituja/poistettuja tietoja (sähköpostirivit, auth-tilit, Storage-tiedostot) rollback ei palauta.
-- Rullaa booking_160 takaisin ENNEN booking_157:n rollbackia. Ajettavissa uudelleen.
set local lock_timeout = '5s';

-- Mahdollinen Storage-siivouksen ajastus pois (manuaali booking_160_retention_cron.sql).
do $$ begin
  if to_regclass('cron.job') is not null and exists (select 1 from cron.job where jobname = 'booking_privacy_storage_cleanup') then
    perform cron.unschedule('booking_privacy_storage_cleanup');
  end if;
end $$;

-- booking._privacy_candidates(date)  md5 860ed2d3493d397c2245722851556849
CREATE OR REPLACE FUNCTION booking._privacy_candidates(p_as_of date)
 RETURNS TABLE(category text, id bigint, blocked text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

-- booking.privacy_retention_report(date)  md5 2af4b398e95c10d8255b2455e3859c67
CREATE OR REPLACE FUNCTION booking.privacy_retention_report(p_as_of date DEFAULT ((now() AT TIME ZONE 'Europe/Helsinki'::text))::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

-- booking.privacy_retention_run()  md5 d67501e18437fa02823abd04a3e2f757
CREATE OR REPLACE FUNCTION booking.privacy_retention_run()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

-- booking.receipts_guard_trg()  md5 928c3105ed1b69ce0a6e4eee955d2a59
CREATE OR REPLACE FUNCTION booking.receipts_guard_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

-- booking.invoices_lock_trg()  md5 f0efc5f40afa919f936e55a6df482a1e
CREATE OR REPLACE FUNCTION booking.invoices_lock_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
end $function$;

-- booking.receipt_by_token(uuid)  md5 1bbc3a0f4ed08b05100b7ffe44278e27
CREATE OR REPLACE FUNCTION booking.receipt_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select booking._receipt_json(rc, false) from booking.receipts rc where rc.public_token = p_token
$function$;

-- booking.invoice_by_token(uuid)  md5 4061b4bf7ceef0ba2464e2160e0f3d48
CREATE OR REPLACE FUNCTION booking.invoice_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select booking._invoice_row(i.id) from booking.invoices i where i.public_token = p_token and i.status <> 'voided'
$function$;

-- booking.svc_get_gift_card_pdf_data(uuid)  md5 4a74a7a12ba5617bc7ad35815db484b6
CREATE OR REPLACE FUNCTION booking.svc_get_gift_card_pdf_data(p_public_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g booking.gift_cards; v_red boolean;
begin
  select * into g from booking.gift_cards where public_token = p_public_token and p_public_token is not null;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Korttia ei löydy'); end if;
  if g.status not in ('active', 'used', 'expired') then return jsonb_build_object('ok', false, 'code', 'not_ready', 'message', 'Kortti aktivoituu kun tilaus on maksettu'); end if;
  v_red := booking._gc_flag('gift_cards.redeem_enabled') and (g.source <> 'johku' or booking._gc_flag('gift_cards.johku_cards_redeemable'));
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'status', case when g.status = 'active' and g.valid_to < booking._gc_today() then 'expired' else g.status end,
    'kind', g.kind, 'package_code', g.package_code,
    'package', (select jsonb_build_object('name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en, 'persons', p.persons, 'items', p.items, 'is_open', p.is_open)
                  from booking.gift_card_packages p where p.code = g.package_code),
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_from', g.valid_from, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name,
    'greeting', g.greeting, 'buyer_name', g.buyer_name, 'locale', g.locale, 'issued_at', coalesce(g.activated_at, g.created_at), 'source', g.source,
    'redeemable_now', v_red, 'seller', booking._seller());
end $function$;

comment on function booking.privacy_retention_run() is 'booking_157: tietosuojan säilytysajo. Vain admin/service_role/pg_cron. Ei tee mitään, ellei privacy_retention.enabled = true. Loki: booking.privacy_retention_runs.';

drop function if exists booking.privacy_storage_due(integer);
drop function if exists booking._privacy_storage_items();
drop function if exists booking._privacy_auth_protected(uuid);
drop function if exists booking._privacy_invoice_snapshot(jsonb);
drop function if exists booking._privacy_keep(jsonb, text[]);

do $$ begin
  if not exists (select 1 from booking.receipts where pdf_deleted_at is not null) then alter table booking.receipts drop column if exists pdf_deleted_at;
  else raise notice 'booking_160 rollback: receipts.pdf_deleted_at jätetään (sisältää merkintöjä)'; end if;
  if not exists (select 1 from booking.invoices where pdf_deleted_at is not null) then alter table booking.invoices drop column if exists pdf_deleted_at;
  else raise notice 'booking_160 rollback: invoices.pdf_deleted_at jätetään (sisältää merkintöjä)'; end if;
  if not exists (select 1 from booking.gift_cards where pdf_deleted_at is not null) then alter table booking.gift_cards drop column if exists pdf_deleted_at;
  else raise notice 'booking_160 rollback: gift_cards.pdf_deleted_at jätetään (sisältää merkintöjä)'; end if;
  if not exists (select 1 from booking.privacy_auth_deletions) then drop table booking.privacy_auth_deletions;
  else raise notice 'booking_160 rollback: booking.privacy_auth_deletions jätetään (ei tyhjä)'; end if;
exception when undefined_column or undefined_table then null;
end $$;

alter table booking.privacy_retention_runs drop constraint if exists privacy_retention_runs_status_check;
do $$ begin
  if exists (select 1 from booking.privacy_retention_runs where status not in ('disabled', 'ok', 'partial')) then
    alter table booking.privacy_retention_runs add constraint privacy_retention_runs_status_check check (status in ('disabled', 'ok', 'partial')) not valid;
  else
    alter table booking.privacy_retention_runs add constraint privacy_retention_runs_status_check check (status in ('disabled', 'ok', 'partial'));
  end if;
end $$;

delete from booking.settings where key in ('privacy_retention.dry_run', 'privacy_retention.gift_card_pdf_years');
update booking.settings set description = 'booking_157: lähetettyjen/päättyneiden sähköpostien payload (vastaanottaja, linkit) tyhjennetään näin monen kuukauden jälkeen.'
 where key = 'privacy_retention.email_outbox_months';

-- Tarkistus: funktiot ovat täsmälleen tuotannon booking_160:tä edeltävät määrittelyt.
do $$
declare r record; v_bad text := '';
begin
  for r in select * from (values
      ('booking._privacy_candidates(date)', '860ed2d3493d397c2245722851556849'),
      ('booking.privacy_retention_report(date)', '2af4b398e95c10d8255b2455e3859c67'),
      ('booking.privacy_retention_run()', 'd67501e18437fa02823abd04a3e2f757'),
      ('booking.receipts_guard_trg()', '928c3105ed1b69ce0a6e4eee955d2a59'),
      ('booking.invoices_lock_trg()', 'f0efc5f40afa919f936e55a6df482a1e'),
      ('booking.receipt_by_token(uuid)', '1bbc3a0f4ed08b05100b7ffe44278e27'),
      ('booking.invoice_by_token(uuid)', '4061b4bf7ceef0ba2464e2160e0f3d48'),
      ('booking.svc_get_gift_card_pdf_data(uuid)', '4a74a7a12ba5617bc7ad35815db484b6')
    ) v(sig, md5)
  loop
    if md5(pg_get_functiondef(r.sig::regprocedure)) is distinct from r.md5 then v_bad := v_bad || ' ' || r.sig; end if;
  end loop;
  if v_bad <> '' then raise exception 'booking_160 rollback: md5 ei täsmää:%', v_bad; end if;
  if to_regprocedure('booking.privacy_storage_due(integer)') is not null or to_regprocedure('booking._privacy_keep(jsonb,text[])') is not null then
    raise exception 'booking_160 rollback: booking_160-funktioita jäi';
  end if;
end $$;
