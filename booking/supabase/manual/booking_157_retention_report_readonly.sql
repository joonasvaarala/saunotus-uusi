-- booking_157: tietosuojan säilytysraportti TUOTANNON LUKUAJOON (pelkkä SELECT, ei kirjoituksia, ei uusia funktioita).
-- Sama ehdokaslohko kuin booking._privacy_candidates (migraatio 20261024290000); node-testi tietosuoja-sailytys.test.mjs varmistaa, että ne ovat identtiset.
-- Tulostaa vain määrät luokittain ja estosyittäin (ei id:itä eikä henkilötietoja). Päivä = tänään (Europe/Helsinki).
-- Ajo: Supabase MCP execute_sql (read-only) tai SQL-editori. Ei vaadi booking_157-migraatiota.
with p0 as (select (now() at time zone 'Europe/Helsinki')::date as as_of),
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
-- </privacy-candidates>,
leads as (
  select 'kb_leads_3y'::text as category, l.id, case when l.marketing_consent then 'marketing_consent' end as blocked
    from kb.leads l cross join p
   where greatest(l.created_at, l.updated_at) < p.cut3
     and (l.name is not null or l.email is not null or l.phone is not null or l.message is not null
          or l.handled_note is not null or l.quiz_answers is not null or l.session_hash is not null)
)
select x.category, coalesce(x.blocked, 'due') as status, count(*)::int as n
  from (select category, id, blocked from cand_all union all select category, id, blocked from leads) x
 group by 1, 2
 order by 1, 2;
