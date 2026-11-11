-- booking_264: maksamattoman tilauksen poisto hallinnasta (arkistointi, ei fyysistä poistoa).
-- Joonas 8.11.2026 klo 18.19 (Bottiavustus t1501u): "Tee mahdollisuus poistaa maksamattomat tilaukset".
--
-- Uutta:
--  * booking.orders.archived_at / archived_by / archive_reason (tyhjät sarakkeet; vain metatieto) + check: arkistoitu ⇒ status = 'cancelled'.
--  * booking._order_delete_blockers(bigint): sisäinen estelista (ei kutsuoikeutta rooleille).
--  * booking.admin_order_delete_check(bigint): hallinnan esikatselu (_require_staff): voiko poistaa, esteet, vaikutukset.
--  * booking.admin_delete_unpaid_order(bigint, text): poisto = arkistointi (bookings.manage + payments.manage).
--  * booking.admin_list_orders: arkistoidut piiloon tavallisista suodattimista, uusi suodatin 'archived'. POIKKEUS: arkistoitu tilaus,
--    jolle on kirjattu maksu (myöhäinen maksu booking_263-polun kautta), näkyy edelleen kaikissa suodattimissa joihin se muuten kuuluu
--    + rivillä archived_late_paid = true. Tarkka tilausnumerohaku löytää arkistoidun.
--
-- Rollout: Joonas 11.11.2026 klo 16.10 Europe/Helsinki ("Maksamattomia tilauksia ei pysty edelleenkään poistamaan. Tämä pitää laittaa korjaukseen heti.").
-- Pohjana booking_276-tila (admin_list_orders = booking_270). Ei edge-deploya.
-- Archive alone uses nonwaiting, complete-set row locks inside a subtransaction.
-- Contention returns busy and releases acquired locks; normal payment/receipt paths are unchanged.
-- Waitlist notifications remain NORMAL (Joonas 8.11.2026 19.10 Europe/Helsinki).
-- Outbox: sending or uncertain/reclaimed claim history blocks archive. This is fail-closed,
-- NOT a promise to stop an old external worker or retract an already accepted email.
-- Late payments use booking_263 unchanged; audit-derived review + one acknowledgment/payment.
-- Full rollback is forbidden once archive, acknowledgment or uncertain dispatch history exists.

set local lock_timeout = '5s';

do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef('booking.payment_mark_paid(text,text,numeric,jsonb)'::regprocedure));
  if v is distinct from 'b35618b8cd17fa9e7c5902719d0804a2' then
    raise exception 'booking_264: payment_mark_paid md5 % ei ole booking_263 (b35618b8…). Ei muutoksia.', v;
  end if;
  v := md5(pg_get_functiondef('booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text)'::regprocedure));
  if v is null or v not in ('56edffa64fbd99c14f8ea3a4bf126cd3', 'cad71198827bd7fd03426f146b43b424') then
    raise exception 'booking_264: admin_list_orders md5 % ei vastaa odotettua (56edffa6… booking_270 / tämä). Ei muutoksia.', v;
  end if;
  -- claim/archive-sopimus nojaa claimin FOR UPDATE SKIP LOCKED + sending samassa transaktiossa -semantiikkaan
  v := md5(pg_get_functiondef('booking.email_outbox_claim_base_132(integer)'::regprocedure));
  if v not in ('0b10986533285645d8592449a90a1e0c', 'c865d1b3d8d6620ff5935c077b7e16a2') then
    raise exception 'booking_264: email_outbox_claim_base_132 md5 % ei vastaa odotettua (0b109865…). Ei muutoksia.', v;
  end if;
  v := md5(pg_get_functiondef('booking.email_outbox_claim_base_146(integer)'::regprocedure));
  if v is distinct from '5bb547fa6a5f9e715ebbb39e6b479d3e' then raise exception 'booking_264: base146 vieras versio %',v; end if;
  v := md5(pg_get_functiondef('booking.email_outbox_claim_base_215(integer)'::regprocedure));
  if v is distinct from '2c76d9c30a28f78e8bb84cce0ff61d77' then raise exception 'booking_264: base215 vieras versio %',v; end if;
  v := md5(pg_get_functiondef('booking.email_outbox_mark(bigint,text,text,text)'::regprocedure));
  if v is distinct from '2ba0222fdfee71942fb09053bd7ea803' then raise exception 'booking_264: outbox mark vieras versio %',v; end if;
  v := md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure));
  if v not in ('5e8125c1da473685b7a7adbb40966250', 'e46ae5ebd9fb813a087b7f05c40949b8') then raise exception 'booking_264: email_outbox_claim vieras versio %',v; end if;
  v := md5(pg_get_functiondef('booking.admin_review_list()'::regprocedure));
  if v not in ('8c7ddb15580659e9daa3e72f43718f14', 'fca45e305e1036d462ef28c7473de150') then raise exception 'booking_264: admin_review_list vieras versio %',v; end if;
  if exists (select 1 from pg_trigger where tgrelid='booking.email_outbox'::regclass and tgname='email_outbox_archived_bi'
     and md5(pg_get_triggerdef(oid)||tgenabled::text) <> 'e8a1a32402444a91417fd625c6a79478') then
    raise exception 'booking_264: vieras triggerin määrittely/tila';
  end if;
  if to_regprocedure('booking.admin_delete_unpaid_order(bigint,text)') is not null
     and not exists (select 1 from pg_trigger where tgrelid='booking.email_outbox'::regclass and tgname='email_outbox_archived_bi') then
    raise exception 'booking_264: osittainen aiempi asennus, trigger puuttuu';
  end if;
  -- Reapplying this migration must never silently re-enable a forward-disabled RPC.
  if to_regprocedure('booking.admin_delete_unpaid_order(bigint,text)') is not null then
    if (select pg_get_userbyid(proowner) from pg_proc where oid='booking.admin_delete_unpaid_order(bigint,text)'::regprocedure) is distinct from 'postgres'
       or (select jsonb_agg(jsonb_build_array(pg_get_userbyid(a.grantor),case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,a.privilege_type,a.is_grantable)
          order by case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,a.privilege_type)
         from pg_proc p cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
         where p.oid='booking.admin_delete_unpaid_order(bigint,text)'::regprocedure)
       is distinct from '[["postgres","authenticated","EXECUTE",false],["postgres","postgres","EXECUTE",false],["postgres","service_role","EXECUTE",false]]'::jsonb then
      raise exception 'booking_264: archive owner/ACL differs or feature is forward-disabled; explicit reviewed re-enable required';
    end if;
  end if;
  -- uudet funktiot: joko puuttuvat tai täsmälleen tämän migraation versio (uudelleenajo); vieras versio → ei muutoksia
  for v in select format('%s md5 %s', x.sig, md5(pg_get_functiondef(to_regprocedure(x.sig))))
             from (values ('booking._archived_late_payment_review_rows()', '035d2f18a860cd62a757187ef3e64a71'),
                          ('booking.admin_ack_archived_late_payment(bigint,text)', 'f3ad2e3c42ea2178fcf297e5c4bbf2eb'),
                          ('booking._order_delete_blockers(bigint)', '21b2feb3e469c6d1cc44cca480657bdb'),
                          ('booking.admin_order_delete_check(bigint)', 'acbc37244b1975ecd0aa9b02c39707df'),
                          ('booking.admin_delete_unpaid_order(bigint,text)', 'ba36be22eaadfc8bdef59b089ad5d629'),
                          ('booking._email_outbox_archived_bi()', '63515bcb6f2b85f003fc3e3125c37f73')) x(sig, ok)
            where to_regprocedure(x.sig) is not null and md5(pg_get_functiondef(to_regprocedure(x.sig))) <> x.ok
  loop
    raise exception 'booking_264: vieras aiempi versio (%). Ei muutoksia.', v;
  end loop;
  if to_regprocedure('booking.admin_delete_unpaid_order(bigint,text)') is not null
     and not exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'orders' and column_name = 'archived_at') then
    raise exception 'booking_264: osittainen aiempi asennus (funktio ilman saraketta). Ei muutoksia.';
  end if;
end $pre$;

alter table booking.orders add column if not exists archived_at timestamptz;
alter table booking.orders add column if not exists archived_by uuid;
alter table booking.orders add column if not exists archive_reason text;
do $c$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'booking.orders'::regclass and conname = 'orders_archived_cancelled') then
    alter table booking.orders add constraint orders_archived_cancelled check (archived_at is null or status = 'cancelled');
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'booking.orders'::regclass and conname = 'orders_archive_reason_len') then
    alter table booking.orders add constraint orders_archive_reason_len check (archive_reason is null or char_length(archive_reason) <= 500);
  end if;
end $c$;
create index if not exists orders_archived_264_idx on booking.orders(id) where archived_at is not null;
create index if not exists audit_late_paid_264_idx on booking.audit_log(row_pk,at) where action='LATE_PAID_CANCELLED_ORDER' and table_name='payments';
comment on column booking.orders.archived_at is 'booking_264: maksamaton tilaus poistettu hallinnasta (arkistoitu). Rivi ja historia säilyvät; tavallisista listoista piilossa.';

alter table booking.email_outbox add column if not exists archive_claim_uncertain boolean not null default false;
-- Any ambiguous attempted history is not proof an old lease owner has stopped.
-- Includes legacy failed1 -> skipped/dry_run; only positively normal first sent is exempt.
-- All kinds retain coverage, and true flags are never reset.
update booking.email_outbox set archive_claim_uncertain = true
 where not archive_claim_uncertain and attempts > 0
   and not (attempts=1 and status='sent' and sent_at is not null);

create or replace function booking._order_delete_blockers(p_order_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  o booking.orders;
  b jsonb := '[]'::jsonb;
  v_prov jsonb;
begin
  select * into o from booking.orders where id = p_order_id;
  if not found then
    return jsonb_build_array(jsonb_build_object('code', 'not_found', 'message', 'Tilausta ei löydy'));
  end if;
  if o.external_source is not null then
    b := b || jsonb_build_object('code', 'external_order', 'message', 'Johkusta tuotu tilaus käsitellään Johkussa');
  end if;
  if o.status = 'completed' then
    b := b || jsonb_build_object('code', 'order_completed', 'message', 'Toteutunutta tilausta ei voi poistaa');
  end if;
  if o.payment_status not in ('unpaid', 'pending', 'failed') then
    b := b || jsonb_build_object('code', 'payment_status', 'message', 'Tilauksen maksutila ei ole maksamaton (' || o.payment_status || ')');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id
              and (p.status in ('paid', 'partially_refunded', 'refunded') or coalesce(p.refunded_amount, 0) > 0)) then
    b := b || jsonb_build_object('code', 'settled_payment', 'message', 'Tilauksella on maksettu tai hyvitetty maksu');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.external_source is not null) then
    b := b || jsonb_build_object('code', 'external_payment', 'message', 'Tilauksella on ulkoisesta järjestelmästä tuotu maksurivi');
  end if;
  if exists (select 1 from booking.receipts x where x.order_id = o.id) then
    b := b || jsonb_build_object('code', 'receipts', 'message', 'Tilauksella on kuitti (kirjanpitohistoria säilytetään)');
  end if;
  if exists (select 1 from booking.refunds x where x.order_id = o.id) then
    b := b || jsonb_build_object('code', 'refunds', 'message', 'Tilauksella on hyvitys');
  end if;
  if exists (select 1 from booking.accounting_outbox x where x.order_id = o.id) then
    b := b || jsonb_build_object('code', 'accounting', 'message', 'Tilaus on kirjanpidon jonossa');
  end if;
  if exists (select 1 from booking.invoices x where x.order_id = o.id)
     or exists (select 1 from booking.payments p where p.order_id = o.id and p.method = 'invoice' and p.status <> 'cancelled')
     or booking._order_invoice_locked(o.id) then
    b := b || jsonb_build_object('code', 'invoice', 'message', 'Tilauksella on lasku: korjaa laskutuksen kautta');
  end if;
  if exists (select 1 from booking.gift_cards g where g.purchase_order_id = o.id
              and (g.status not in ('pending_payment', 'cancelled') or (g.status = 'pending_payment' and o.status in ('cancelled', 'expired'))))
     or exists (select 1 from booking.gift_card_ledger l where l.order_id = o.id and not (l.reason = 'cancel' and l.delta = 0))
     or exists (select 1 from booking.payments p where p.order_id = o.id and (p.method = 'gift_card' or p.gift_card_id is not null)) then
    b := b || jsonb_build_object('code', 'gift_card', 'message', 'Tilaukseen liittyy lahjakortti tai lahjakorttimaksu');
  end if;
  if exists (select 1 from booking.annual_cards a where a.purchase_order_id = o.id) then
    b := b || jsonb_build_object('code', 'annual_card', 'message', 'Tilaukseen liittyy vuosikortti');
  end if;
  if exists (select 1 from booking.voucher_claims v where v.order_id = o.id and v.status not in ('cancelled', 'expired'))
     or exists (select 1 from booking.vc_difference_payments d where d.order_id = o.id) then
    b := b || jsonb_build_object('code', 'voucher_claim', 'message', 'Tilaukseen liittyy kumppanilahjakortin lunastus');
  end if;
  if exists (select 1 from booking.training_participants t where t.order_id = o.id) then
    b := b || jsonb_build_object('code', 'training', 'message', 'Koulutuksen osallistuja: käsittele koulutustyökalussa');
  end if;
  if exists (select 1 from booking.reservations r where r.order_id = o.id
              and (r.status in ('completed', 'no_show') or (r.status in ('pending', 'confirmed') and r.starts_at <= now()))) then
    b := b || jsonb_build_object('code', 'reservation_started', 'message', 'Varaus on jo alkanut tai toteutunut');
  end if;
  if exists (select 1 from booking.reservations c join booking.reservations p on p.id = c.parent_reservation_id
              where p.order_id = o.id and c.order_id <> o.id and c.status in ('pending', 'confirmed')) then
    b := b || jsonb_build_object('code', 'linked_reservations', 'message', 'Toisen tilauksen voimassa oleva lisäpalvelu on kiinni tämän tilauksen varauksessa');
  end if;
  select coalesce(jsonb_agg(x order by (x ->> 'payment_id')::bigint, x ->> 'ref'), '[]'::jsonb) into v_prov from (
    select jsonb_build_object('payment_id', p.id, 'provider', 'montonio', 'ref', a.order_number, 'current', a.order_number = p.provider_ref,
             'payment_status', p.status, 'last_state', p.raw ->> 'last_state', 'outcome', a.outcome, 'started_at', a.created_at,
             'checkable', p.status = 'pending' and a.order_number = p.provider_ref and coalesce(p.raw ->> 'last_state', '') <> 'create_failed'
                          and nullif(p.raw ->> 'order_uuid', '') is not null) as x
      from booking.payments p join booking.montonio_attempts a on a.payment_id = p.id
     where p.order_id = o.id and coalesce(a.outcome, '') <> 'cancelled'
       and not (a.outcome = 'paid' and p.status in ('paid','partially_refunded','refunded'))  -- paid/pending contradiction fails closed
    union all
    select jsonb_build_object('payment_id', p.id, 'provider', 'montonio', 'ref', p.provider_ref, 'current', true, 'payment_status', p.status,
             'last_state', p.raw ->> 'last_state', 'outcome', null, 'started_at', null, 'checkable', false, 'no_attempt_row', true)
      from booking.payments p
     where p.order_id = o.id and nullif(p.provider_ref, '') is not null and p.provider_ref not like 'dryrun-%'
       and not (coalesce(p.provider,'') in ('mobilepay','visma_pay') or coalesce(p.raw,'{}'::jsonb) ?| array['mobilepay','visma','visma_pay'])
       and not exists (select 1 from booking.montonio_attempts a where a.order_number = p.provider_ref and a.payment_id = p.id)
    union all
    select jsonb_build_object('payment_id', p.id, 'provider', p.provider, 'ref', p.provider_ref, 'current', true, 'payment_status', p.status,
             'last_state', coalesce(p.raw #>> '{mobilepay,last_state}', p.provider_status), 'outcome', null, 'started_at', null, 'checkable', false)
      from booking.payments p
     where p.order_id = o.id and (p.provider in ('mobilepay', 'visma_pay') or p.raw ? 'mobilepay' or p.raw ? 'visma' or p.raw ? 'visma_pay')
       -- KAIKKI viitteelliset MobilePay/Visma-rivit tilasta riippumatta: paikallinen cancelled/failed ei todista veloittamattomuutta
       and (p.provider_ref is not null
            or (jsonb_typeof(p.raw) = 'object' and (p.raw ? 'mobilepay' or p.raw ? 'visma' or p.raw ? 'visma_pay')))
    union all
    select jsonb_build_object('payment_id', p.id, 'provider', 'visma_pay', 'ref', a.order_number, 'checkable', false, 'historical', true)
      from booking.payments p join booking.vismapay_attempts a on a.payment_id = p.id where p.order_id = o.id
  ) s;
  if exists (select 1 from booking.email_outbox e where (e.order_id = o.id or e.payment_id in (select id from booking.payments where order_id = o.id))
              and (e.archive_claim_uncertain or e.attempts > 1 or (e.attempts > 0 and e.status = 'pending'))) then
    b := b || jsonb_build_object('code', 'email_claim_uncertain', 'message', 'Sähköpostin aiemman lähetysyrityksen päättymistä ei voida todistaa. Poisto estetään; vanhaa ulkoista lähetystä ei voi perua.');
  end if;
  if exists (select 1 from booking.email_outbox e where (e.order_id = o.id or e.payment_id in (select id from booking.payments where order_id = o.id)) and e.status = 'sending') then
    b := b || jsonb_build_object('code', 'email_sending', 'message', 'Tilauksen sähköpostia lähetetään parhaillaan; lähetystä ei voi perua. Yritä hetken kuluttua uudelleen.');
  end if;
  if jsonb_array_length(v_prov) > 0 then
    b := b || jsonb_build_object('code', 'provider_session_unresolved',
      'message', 'Maksupalvelussa on avattu maksu, jonka päättymistä maksupalvelu ei ole vahvistanut. Avattua maksua ei voi sulkea meidän päästämme.',
      'sessions', v_prov);
  end if;
  return b;
end $$;

create or replace function booking.admin_order_delete_check(p_order_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; v_b jsonb; v_late boolean; v_token uuid;
begin
  perform booking._require_staff();
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  v_late := exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid', 'partially_refunded', 'refunded'));
  if o.archived_at is not null then
    return jsonb_build_object('ok', true, 'order_id', o.id, 'order_no', o.order_no, 'archived', true, 'archived_at', o.archived_at,
      'archive_reason', o.archive_reason, 'late_paid', v_late, 'deletable', false, 'blockers', '[]'::jsonb,
      'can_delete', booking.has_permission('bookings.manage') and booking.has_permission('payments.manage'));
  end if;
  v_b := booking._order_delete_blockers(o.id);
  if exists (select 1 from jsonb_array_elements(v_b) e, jsonb_array_elements(coalesce(e -> 'sessions', '[]'::jsonb)) s
              where (s ->> 'checkable')::boolean) then
    v_token := o.public_token;
  end if;
  return jsonb_build_object('ok', true, 'order_id', o.id, 'order_no', o.order_no, 'archived', false, 'late_paid', v_late,
    'can_delete', booking.has_permission('bookings.manage') and booking.has_permission('payments.manage'),
    'deletable', jsonb_array_length(v_b) = 0, 'blockers', v_b, 'verify_order_token', v_token,
    'effects', jsonb_build_object(
      'reservations', (select count(*) from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed')),
      'pending_payments', (select count(*) from booking.payments p where p.order_id = o.id and p.status = 'pending'),
      'open_links', (select count(*) from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.link_sent_at is not null),
      'queued_emails', (select count(*) from booking.email_outbox e where (e.order_id = o.id or e.payment_id in (select id from booking.payments where order_id = o.id)) and e.status in ('pending', 'failed')),
      'order_status', o.status));
end $$;

create or replace function booking.admin_delete_unpaid_order(p_order_id bigint, p_reason text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  o booking.orders;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_b jsonb;
  v_res_before jsonb; v_pay_before jsonb;
  v_res_ids bigint[]; v_pay_ids bigint[]; v_mails int;
  v_late boolean;
  v_expected bigint[]; v_locked bigint[]; k record;
begin
  perform booking._require_permission('bookings.manage');
  perform booking._require_permission('payments.manage');
  if p_order_id is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if v_reason is not null and char_length(v_reason) > 500 then perform booking._err('invalid_param', 'Syy on liian pitkä (enintään 500 merkkiä)'); end if;

  begin -- all acquired locks are released on busy/blocker via subtransaction rollback
  -- Shared archive-only gate: rollback takes exclusive BEFORE checking usage data.
  if not pg_try_advisory_xact_lock_shared(hashtextextended('booking:archive:264',0)) then
    raise sqlstate 'B2640';
  end if;
  select * into o from booking.orders where id = p_order_id for update skip locked;
  if not found then
    if exists (select 1 from booking.orders where id = p_order_id) then raise sqlstate 'B2640' using message = 'busy'; end if;
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if o.archived_at is not null then
    v_late := exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded'));
    return jsonb_build_object('ok', true, 'already', true, 'order_id', o.id, 'order_no', o.order_no, 'archived_at', o.archived_at, 'late_paid', v_late);
  end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.payments x where x.order_id = o.id;
  select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
    (select x.id from booking.payments x where x.id = any(v_expected) order by x.id for update skip locked) z;
  if v_expected is distinct from v_locked then raise sqlstate 'B2640' using message = 'busy:payments'; end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.reservations x where x.order_id = o.id;
  select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
    (select x.id from booking.reservations x where x.id = any(v_expected) order by x.id for update skip locked) z;
  if v_expected is distinct from v_locked then raise sqlstate 'B2640' using message = 'busy:reservations'; end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.reservation_legs x where x.reservation_id in (select id from booking.reservations where order_id = o.id);
  select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
    (select x.id from booking.reservation_legs x where x.id = any(v_expected) order by x.id for update skip locked) z;
  if v_expected is distinct from v_locked then raise sqlstate 'B2640' using message = 'busy:reservation_legs'; end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.gift_cards x where x.purchase_order_id = o.id;
  select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
    (select x.id from booking.gift_cards x where x.id = any(v_expected) order by x.id for update skip locked) z;
  if v_expected is distinct from v_locked then raise sqlstate 'B2640' using message = 'busy:gift_cards'; end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.discount_codes x where x.id = o.discount_code_id;
  select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
    (select x.id from booking.discount_codes x where x.id = any(v_expected) order by x.id for update skip locked) z;
  if v_expected is distinct from v_locked then raise sqlstate 'B2640' using message = 'busy:discount_codes'; end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_expected from booking.email_outbox x where (x.order_id = o.id or x.payment_id in (select id from booking.payments where order_id = o.id));
  select coalesce(array_agg(z.id order by z.id), '{}') into v_locked from
    (select x.id from booking.email_outbox x where x.id = any(v_expected) order by x.id for update skip locked) z;
  if v_expected is distinct from v_locked then raise sqlstate 'B2640' using message = 'busy:email_outbox'; end if;
  -- Existing waitlist protocol already uses try-locks, not a new global protocol.
  -- Claim space keys before cancellation; a concurrent capacity worker makes THIS archive busy.
  for k in select distinct r.space_id from booking.reservations r where r.order_id = o.id and r.space_id is not null order by r.space_id loop
    if not pg_try_advisory_xact_lock(hashtextextended('booking:space:' || k.space_id::text, 0)) then
      raise sqlstate 'B2640' using message = 'busy:space';
    end if;
  end loop;

  v_b := booking._order_delete_blockers(o.id);
  if jsonb_array_length(v_b) > 0 then
    raise sqlstate 'B2641' using message = 'blocked';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'starts_at', r.starts_at) order by r.id), '[]'::jsonb)
    into v_res_before from booking.reservations r where r.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'status', p.status, 'provider', p.provider, 'method', p.method, 'amount', p.amount,
                                               'link', p.link_token is not null) order by p.id), '[]'::jsonb)
    into v_pay_before from booking.payments p where p.order_id = o.id;

  with u as (
    update booking.reservations r
       set status = 'cancelled', cancelled_at = coalesce(r.cancelled_at, now()), cancel_reason = 'order_deleted_unpaid'
     where r.order_id = o.id and r.status in ('pending', 'confirmed')
    returning r.id)
  select coalesce(array_agg(id order by id), '{}') into v_res_ids from u;

  with u as (
    update booking.payments p
       set status = 'cancelled',
           reminders_handled_at = coalesce(p.reminders_handled_at, now()),
           note = concat_ws(' | ', p.note, 'tilaus poistettu (maksamaton)'),
           raw = coalesce(case when jsonb_typeof(p.raw) = 'object' then p.raw end, '{}'::jsonb)
                 || jsonb_build_object('booking_264', jsonb_build_object('prev_status', p.status, 'at', now()))
     where p.order_id = o.id and p.status = 'pending'
    returning p.id)
  select coalesce(array_agg(id order by id), '{}') into v_pay_ids from u;

  update booking.orders
     set status = 'cancelled',
         cancelled_at = coalesce(cancelled_at, now()),
         payment_status = 'unpaid',
         archived_at = now(),
         archived_by = auth.uid(),
         archive_reason = v_reason,
         internal_note = concat_ws(E'\n', internal_note, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI')
                                   || ' Poistettu maksamattomana' || coalesce(': ' || v_reason, '')),
         external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('booking_264', jsonb_build_object(
           'prev_status', o.status, 'prev_payment_status', o.payment_status, 'prev_cancelled_at', o.cancelled_at, 'at', now()))
   where id = o.id;

  update booking.email_outbox e
     set status = 'skipped', last_error = 'booking_264: tilaus poistettu maksamattomana'
   where (e.order_id = o.id or e.payment_id in (select id from booking.payments where order_id = o.id)) and e.status in ('pending', 'failed');  -- failed = claim yrittäisi uudelleen
  get diagnostics v_mails = row_count;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, 'ORDER_DELETED_UNPAID',
          jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'cancelled_at', o.cancelled_at,
                             'reservations', v_res_before, 'payments', v_pay_before),
          jsonb_build_object('order_no', o.order_no, 'status', 'cancelled', 'payment_status', 'unpaid', 'reason', v_reason,
                             'cancelled_reservation_ids', to_jsonb(v_res_ids), 'cancelled_payment_ids', to_jsonb(v_pay_ids), 'skipped_emails', v_mails));

  return jsonb_build_object('ok', true, 'order_id', o.id, 'order_no', o.order_no, 'archived_at', now(),
    'cancelled_reservation_ids', to_jsonb(v_res_ids), 'cancelled_payment_ids', to_jsonb(v_pay_ids), 'skipped_emails', v_mails);
  exception
    when sqlstate 'B2640' then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Tilausta käsitellään parhaillaan. Yritä uudelleen.');
    when sqlstate 'B2641' then
      return jsonb_build_object('ok', false, 'code', v_b -> 0 ->> 'code', 'message', v_b -> 0 ->> 'message', 'blockers', v_b, 'order_id', o.id, 'order_no', o.order_no);
  end;
end $$;

-- admin_list_orders: booking_270-runko (laskukentät) + booking_264-suodatus (diff: archived-suodatin, arkistoidun piilotus/poikkeukset, rivikentät archived_at/archived_late_paid)
CREATE OR REPLACE FUNCTION booking.admin_list_orders(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_payment_status text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_native boolean DEFAULT NULL::boolean, p_date_field text DEFAULT 'created'::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_sort text DEFAULT 'created_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_payment_filter text DEFAULT 'paid'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_num bigint;
  v_like text;
  v_total int;
  v_rows jsonb;
  v_lim int := coalesce(p_limit, 50);
  v_off int := greatest(coalesce(p_offset, 0), 0);
  v_pf text := coalesce(nullif(btrim(p_payment_filter), ''), 'paid');
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('created_desc','created_asc','order_no_desc','order_no_asc','total_desc','total_asc','start_desc','start_asc','paid_desc','paid_asc','unpaid_desc') then
    perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if coalesce(p_date_field, 'created') not in ('created','start') then perform booking._err('invalid_param', 'p_date_field: created|start'); end if;
  if v_pf not in ('paid','unpaid','all','refunded','cancelled','invoiced','archived') then
    perform booking._err('invalid_param', 'p_payment_filter: paid|unpaid|all|refunded|cancelled|invoiced|archived'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select o.id, o.order_no, o.johku_order_no, o.created_at, o.status, o.payment_status, o.source_channel, (o.external_source is null) as is_native, o.total_gross,
           pp.paid, pp.refunded, pp.pc, pp.lp, rr.fs, rr.le, rr.cnt, rcc.rc,
           inv.id as invoice_id, inv.invoice_no, inv.status as invoice_status, inv.kind as invoice_kind,
           case when o.status in ('cancelled','expired','draft') then 0 else greatest(o.total_gross - (pp.paid - pp.refunded), 0) end as unpaid,
           c.id as cid, c.name as cname, c.company as ccompany, o.customer_kind,
           o.archived_at
      from booking.orders o
      left join booking.customers c on c.id = o.customer_id
      left join lateral (select min(r.starts_at) fs, max(r.ends_at) le, count(*) cnt from booking.reservations r where r.order_id = o.id and r.hidden_at is null) rr on true
      left join lateral (select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0) paid, coalesce(sum(p.refunded_amount), 0) refunded,
                                count(*) filter (where p.status in ('paid','partially_refunded','refunded')) pc, max(p.paid_at) lp
                           from booking.payments p where p.order_id = o.id) pp on true
      left join lateral (select count(*) rc from booking.receipts x where x.order_id = o.id) rcc on true
      left join lateral (
        select i.id,
               i.invoice_no,
               case
                 when i.status = 'sent' and i.due_date < (timezone('Europe/Helsinki', now()))::date
                 then 'overdue'
                 else i.status
               end as status,
               i.kind
          from booking.invoices i
         where i.order_id = o.id
         order by case when i.status = 'voided' then 1 else 0 end,
                  i.created_at desc,
                  i.id desc
         limit 1
      ) inv on true
     where (p_status is null or o.status = p_status)
       and (p_payment_status is null or o.payment_status = p_payment_status)
       and (p_source is null or o.source_channel = p_source)
       and (p_native is null or (o.external_source is null) = p_native)
       -- booking_264: arkistoitu (poistettu maksamaton) vain 'archived'-suodattimessa, tarkassa numerohaussa tai jos sille on kirjattu maksu (myöhäinen maksu näkyy)
       and (o.archived_at is null or v_pf = 'archived' or pp.pc > 0 or (v_num is not null and (o.order_no = v_num or o.johku_order_no = v_num)))
       and (v_s is null or (v_num is not null and (o.order_no = v_num or o.johku_order_no = v_num))
            or (v_num is null and (c.name ilike v_like or c.email ilike v_like or c.phone ilike v_like or c.company ilike v_like)))
       and (p_from is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end >= p_from)
       and (p_to   is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end <= p_to)
       and case v_pf
             when 'all' then true
             when 'paid' then o.payment_status in ('paid','partially_refunded')
               and o.status not in ('cancelled','expired')
               and (case when pp.pc > 0 then pp.paid - pp.refunded
                         when o.payment_status in ('paid','partially_refunded') then o.total_gross
                         else 0 end) > 0.004
             when 'unpaid' then o.payment_status in ('unpaid','pending','failed','partially_paid')
               and o.status not in ('cancelled','expired')
             when 'refunded' then o.payment_status in ('refunded','partially_refunded')
             when 'cancelled' then o.status in ('cancelled','expired')
             when 'invoiced' then o.payment_status = 'invoiced' and o.status not in ('cancelled','expired')
             when 'archived' then o.archived_at is not null
             else false
           end
  ), page as (
    select b.*, row_number() over (order by
        case when p_sort = 'created_asc' then b.created_at end asc, case when p_sort = 'created_desc' then b.created_at end desc,
        case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc,
        case when p_sort = 'total_asc' then b.total_gross end asc, case when p_sort = 'total_desc' then b.total_gross end desc,
        case when p_sort = 'start_asc' then b.fs end asc nulls last, case when p_sort = 'start_desc' then b.fs end desc nulls last,
        case when p_sort = 'paid_asc' then b.lp end asc nulls last, case when p_sort = 'paid_desc' then b.lp end desc nulls last,
        case when p_sort = 'unpaid_desc' then b.unpaid end desc, b.id desc) as rn
      from base b
  )
  select (select count(*) from base),
         coalesce(jsonb_agg(jsonb_build_object('order_id', p.id, 'order_no', p.order_no, 'johku_order_no', p.johku_order_no, 'created_at', p.created_at, 'status', p.status,
           'payment_status', p.payment_status, 'source_channel', p.source_channel, 'is_native', p.is_native, 'total', p.total_gross, 'paid', p.paid, 'refunded', p.refunded,
           'unpaid', p.unpaid, 'customer_id', p.cid, 'customer_name', p.cname, 'customer_company', p.ccompany, 'customer_kind', p.customer_kind, 'first_start', p.fs, 'last_end', p.le,
           'reservation_count', p.cnt, 'payment_count', p.pc, 'last_paid_at', p.lp, 'receipt_count', p.rc,
           'invoice_id', p.invoice_id, 'invoice_no', p.invoice_no, 'invoice_status', p.invoice_status, 'invoice_kind', p.invoice_kind,
           'archived_at', p.archived_at, 'archived_late_paid', p.archived_at is not null and p.pc > 0) order by p.rn), '[]'::jsonb)
    into v_total, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $function$;

-- INSERT: order gate precedes both FK checks. UPDATE: never wait on order while owning outbox.
create or replace function booking._email_outbox_archived_bi()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_arch timestamptz; v_order bigint; v_payment_order bigint;
begin
  if tg_op = 'UPDATE' then
    new.archive_claim_uncertain := old.archive_claim_uncertain or new.archive_claim_uncertain
      or (old.status = 'sending' and new.status in ('pending','failed','dead'))
      or (new.status in ('failed','dead') and new.attempts > 0) or new.attempts > 1;
  else
    new.archive_claim_uncertain := coalesce(new.archive_claim_uncertain, false)
      or (new.status in ('failed','dead') and new.attempts > 0) or new.attempts > 1;
  end if;
  if new.status not in ('pending','failed','sending')
     or new.kind not in ('payment_link','payment_link_reminder','order_confirmation','order_change','unpaid_booking_cancelled') then
    return new;
  end if;
  if new.payment_id is not null then
    select order_id into v_payment_order from booking.payments where id = new.payment_id;
    if new.order_id is not null and v_payment_order is not null and new.order_id <> v_payment_order then
      raise exception 'booking_264: outbox order/payment mismatch';
    end if;
  end if;
  v_order := coalesce(new.order_id, v_payment_order);
  if v_order is null then return new; end if;
  if tg_op = 'INSERT' then
    select o.archived_at into v_arch from booking.orders o where o.id = v_order for key share;
  else
    select o.archived_at into v_arch from booking.orders o where o.id = v_order for key share skip locked;
    if not found and exists (select 1 from booking.orders where id = v_order) then
      -- Final failure / recycled lease records uncertainty, not a new dispatch.
      if new.status <> 'sending' and new.archive_claim_uncertain then return new; end if;
      -- Per-row skip: outer claim only returns rows actually transitioned to sending.
      return null;
    end if;
  end if;
  if v_arch is not null then
    new.status := 'skipped';
    new.last_error := 'booking_264: tilaus poistettu maksamattomana';
  end if;
  return new;
end $$;
drop trigger if exists email_outbox_archived_bi on booking.email_outbox;
create trigger email_outbox_archived_bi before insert or update on booking.email_outbox
  for each row execute function booking._email_outbox_archived_bi();
revoke all on function booking._email_outbox_archived_bi() from public, anon, authenticated;

revoke all on function booking._order_delete_blockers(bigint) from public, anon, authenticated;
revoke all on function booking.admin_order_delete_check(bigint) from public, anon;
revoke all on function booking.admin_delete_unpaid_order(bigint, text) from public, anon;
grant execute on function booking.admin_order_delete_check(bigint) to authenticated, service_role;
grant execute on function booking.admin_delete_unpaid_order(bigint, text) to authenticated, service_role;

-- Acknowledgments only: the queue itself is derived from booking_263's existing audit.
create table if not exists booking.archived_late_payment_acks (
  payment_id bigint primary key references booking.payments(id) on delete restrict,
  acknowledged_at timestamptz not null default now(),
  acknowledged_by uuid not null,
  note text not null check (char_length(btrim(note)) between 3 and 1000)
);
alter table booking.archived_late_payment_acks enable row level security;
revoke all on booking.archived_late_payment_acks from public, anon, authenticated;
grant select on booking.archived_late_payment_acks to authenticated;
grant all on booking.archived_late_payment_acks to service_role;
drop policy if exists staff_read on booking.archived_late_payment_acks;
create policy staff_read on booking.archived_late_payment_acks for select to authenticated using ((select booking.has_permission('payments.manage')));

create or replace function booking._archived_late_payment_review_rows()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'order_id', o.id, 'order_no', o.order_no,
      'amount', p.amount, 'provider', p.provider, 'paid_at', a.at, 'customer_name', c.name) order by a.at, p.id), '[]'::jsonb)
    from booking.payments p join booking.orders o on o.id = p.order_id
    left join booking.customers c on c.id = o.customer_id
    join lateral (select min(l.at) at from booking.audit_log l
      where l.action = 'LATE_PAID_CANCELLED_ORDER' and l.table_name = 'payments' and l.row_pk = p.id::text
        -- Do not compare transaction timestamps: callback may begin before archive commits.
    ) a on a.at is not null
   where o.archived_at is not null
     and not exists (select 1 from booking.archived_late_payment_acks x where x.payment_id = p.id);
$$;

create or replace function booking.admin_ack_archived_late_payment(p_payment_id bigint, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_note text := btrim(coalesce(p_note,'')); v_n int;
begin
  perform booking._require_permission('payments.manage');
  if auth.uid() is null then perform booking._err('forbidden', 'Henkilökohtainen kirjautuminen vaaditaan'); end if;
  if char_length(v_note) not between 3 and 1000 then perform booking._err('invalid_param', 'Kirjoita käsittelyselite (3–1000 merkkiä)'); end if;
  if not exists (select 1 from booking.payments p join booking.orders o on o.id = p.order_id
      join booking.audit_log a on a.table_name = 'payments' and a.row_pk = p.id::text and a.action = 'LATE_PAID_CANCELLED_ORDER'
      where p.id = p_payment_id and o.archived_at is not null) then
    perform booking._err('not_found', 'Arkistoidun tilauksen myöhäismaksua ei löydy');
  end if;
  insert into booking.archived_late_payment_acks(payment_id, acknowledged_by, note) values (p_payment_id, auth.uid(), v_note)
    on conflict (payment_id) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 1 then
    insert into booking.audit_log(actor,actor_role,table_name,row_pk,action,new_data)
    values(auth.uid(),booking._jwt_role(),'payments',p_payment_id::text,'ARCHIVED_LATE_PAYMENT_ACKNOWLEDGED',jsonb_build_object('note',v_note));
  end if;
  return jsonb_build_object('ok',true,'already',v_n = 0,'payment_id',p_payment_id);
end $$;
revoke all on function booking._archived_late_payment_review_rows() from public,anon,authenticated;
revoke all on function booking.admin_ack_archived_late_payment(bigint,text) from public,anon;
grant execute on function booking.admin_ack_archived_late_payment(bigint,text) to authenticated,service_role;

CREATE OR REPLACE FUNCTION booking.admin_review_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'archived_late_payments', case when booking.has_permission('payments.manage') then booking._archived_late_payment_review_rows() else '[]'::jsonb end,
    'therapist_conflicts', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'leg_id', c.leg_id, 'starts_at', c.claim_start, 'ends_at', c.claim_end, 'skill', c.skill) order by c.claim_start)
        from booking.v_claims c where c.role = 'therapist' and not c.is_override and booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()
         and booking._therapist_slack(c.skill, c.claim_start, c.claim_end, c.persons, c.session_key, c.leg_id, c.reservation_id) < 0), '[]'::jsonb),
    'block_conflicts', coalesce((select jsonb_agg(jsonb_build_object(
            'reservation_id', p.reservation_id, 'leg_id', p.leg_id, 'resource_id', p.resource_id, 'block_id', p.block_id,
            'closure_event_id', p.closure_event_id, 'starts_at', p.claim_start, 'ends_at', p.claim_end,
            'block_reason', p.block_reason, 'closure_reason', p.closure_reason, 'calendar_name', p.calendar_name) order by p.claim_start)
        from booking._block_conflict_pairs() p
       where not exists (
         select 1 from booking.closure_conflict_acks a
          where a.reservation_id = p.reservation_id and a.block_id = p.block_id
            and a.revoked_at is null and a.block_signature = p.block_signature)), '[]'::jsonb),
    'acked_block_conflicts', coalesce((select jsonb_agg(jsonb_build_object(
            'reservation_id', p.reservation_id, 'leg_id', p.leg_id, 'resource_id', p.resource_id, 'block_id', p.block_id,
            'closure_event_id', p.closure_event_id, 'starts_at', p.claim_start, 'ends_at', p.claim_end,
            'block_reason', p.block_reason, 'closure_reason', p.closure_reason, 'calendar_name', p.calendar_name,
            'ack_id', a.id, 'ack_reason', a.ack_reason, 'acked_by_label', a.acked_by_label, 'acked_at', a.acked_at) order by p.claim_start)
        from booking._block_conflict_pairs() p
        join booking.closure_conflict_acks a
          on a.reservation_id = p.reservation_id and a.block_id = p.block_id
         and a.revoked_at is null and a.block_signature = p.block_signature), '[]'::jsonb),
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'reason', r.override_reason, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r where r.override_reason is not null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'orphan_addons', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and cardinality(pc.requires_parent_product_ids) > 0
        left join booking.reservations pr on pr.id = r.parent_reservation_id
       where r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at) and r.override_reason is null
         and (pr.id is null or not booking._res_active(pr.status, pr.hold_expires_at))), '[]'::jsonb),
    'missing_therapist', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'product_id', r.product_id,
              'product_name', coalesce(p.name, ''), 'persons', r.persons, 'order_no', o.order_no, 'source', coalesce(r.external_source, 'native'),
              'days_to_start', ((r.starts_at at time zone 'Europe/Helsinki')::date - (now() at time zone 'Europe/Helsinki')::date)) order by r.starts_at)
        from booking.reservations r join booking.orders o on o.id = r.order_id left join kb.products p on p.id = r.product_id
       where r.therapist_missing and r.therapist_exception_at is null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)
         and not exists (select 1 from booking.reservation_legs l where l.reservation_id = r.id and l.role = 'therapist')), '[]'::jsonb));
end $function$;

notify pgrst, 'reload schema';

-- Narrow base132 candidate loop; payload SELECT is exactly the baseline definition.
CREATE OR REPLACE FUNCTION booking.email_outbox_claim_base_132(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[] := '{}'::bigint[]; v_id bigint; v_status text; v_after bigint := 0; v_highwater bigint;
        v_limit integer := greatest(least(coalesce(p_limit,20),50),1); v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  -- The limit counts successful sending transitions, not busy candidates.
  -- A fixed ID highwater makes this finite even with concurrent INSERTs.
  select coalesce(max(id),0) into v_highwater from booking.email_outbox;
  loop
    begin
      v_id := null;
      select e.id into v_id from booking.email_outbox e
       where e.status in ('pending','failed') and e.next_attempt_at <= now()
         and e.id > v_after and e.id <= v_highwater
       order by e.id limit 1 for update skip locked;
      exit when v_id is null;
      v_after := v_id; -- PL/pgSQL variables survive the intentional subtransaction rollback.
      v_status := null;
      update booking.email_outbox set status='sending', locked_at=now(), attempts=attempts+1
       where id=v_id returning status into v_status;
      if not found then
        -- Only our own private code is caught; no timeout/deadlock is swallowed.
        raise exception using errcode='P2B64', message='booking264 internal busy candidate';
      end if;
      if v_status='sending' then v_ids := array_append(v_ids,v_id); end if;
      -- archived -> skipped persists, but does not consume a dispatch slot.
    exception when sqlstate 'P2B64' then null; -- release this candidate's row locks
    end;
    exit when cardinality(v_ids) >= v_limit;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', coalesce(nullif(e.payload ->> 'to_email', ''), c.email), 'to_name', coalesce(nullif(e.payload ->> 'to_name', ''), c.name),
      'reply_to', case when e.kind = 'business_quote_notify' then coalesce(nullif(btrim(e.payload ->> 'reply_to'), ''), nullif(btrim(q.email), '')) end,
      'quote', case when e.kind in ('business_quote_ack', 'business_quote_notify') then jsonb_strip_nulls(jsonb_build_object(
          'id', coalesce(q.id, case when e.payload ->> 'quote_id' ~ '^[0-9]+$' then (e.payload ->> 'quote_id')::bigint end),
          'company_name', coalesce(nullif(btrim(e.payload ->> 'company_name'), ''), q.company_name),
          'contact_name', coalesce(nullif(btrim(e.payload ->> 'contact_name'), ''), q.contact_name),
          'email', coalesce(nullif(btrim(e.payload ->> 'email'), ''), q.email),
          'phone', coalesce(nullif(btrim(e.payload ->> 'phone'), ''), q.phone),
          'persons', coalesce(nullif(e.payload ->> 'persons', '')::int, q.persons),
          'offerings', coalesce(e.payload -> 'offerings', to_jsonb(q.offerings)),
          'offering_other', coalesce(nullif(btrim(e.payload ->> 'offering_other'), ''), q.offering_other),
          'preferred_when', coalesce(nullif(btrim(e.payload ->> 'preferred_when'), ''), q.preferred_when),
          'message', coalesce(nullif(btrim(e.payload ->> 'message'), ''), q.message),
          'locale', coalesce(nullif(btrim(e.payload ->> 'locale'), ''), q.locale),
          'created_at', coalesce(nullif(e.payload ->> 'created_at', ''), to_jsonb(q.created_at) #>> '{}')
        )) end,
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'instructions', case when e.kind = 'order_confirmation' then booking._order_short_instructions(o.id, coalesce(nullif(e.locale, ''), o.locale, 'fi')) else '[]'::jsonb end,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status, 'option', booking._option_json(r.product_option_id)) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'gift_cards', case when e.kind like 'gift_card\_%' then (select coalesce(jsonb_agg(jsonb_build_object('public_token', g.public_token, 'package_code', g.package_code, 'package_name', pk.name, 'package_name_en', pk.name_en,
            'kind', g.kind, 'amount', g.initial_amount, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'greeting', g.greeting, 'buyer_name', g.buyer_name, 'persons', pk.persons,
            'locale', g.locale, 'status', g.status, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'),
            'deliver_at', booking._gc_deliver_ts(g.deliver_on, g.deliver_time), 'delivered_at', g.delivered_at,
            'recipient_email', case when e.kind = 'gift_card_buyer' then g.recipient_email end, 'cover_message', case when e.kind = 'gift_card_recipient' then g.cover_message end) order by g.id), '[]'::jsonb)
          from booking.gift_cards g left join booking.gift_card_packages pk on pk.code = g.package_code
         where g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)) end,
      'voucher_claim', case when e.kind like 'voucher\_claim\_%' then (select jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
            'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name) from booking.voucher_claims vc where vc.id = (e.payload ->> 'claim_id')::bigint) end,
      'product_message', case when e.kind = 'product_message' then booking._product_message_mail(e.id) end,
      'invoice', case when e.kind = 'invoice_pdf' then (select jsonb_build_object('id', inv.id, 'invoice_no', inv.invoice_no, 'public_token', inv.public_token, 'total', inv.total_gross, 'due_date', inv.due_date, 'reference_no', inv.reference_no, 'status', inv.status) from booking.invoices inv where inv.id = nullif(e.payload ->> 'invoice_id', '')::bigint) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
    left join booking.business_quote_requests q
      on e.kind in ('business_quote_ack', 'business_quote_notify')
     and q.id = case when e.payload ->> 'quote_id' ~ '^[0-9]+$' then (e.payload ->> 'quote_id')::bigint end
   where e.id = any (v_ids);
  return v_res;
end $function$;


-- Outer-RPC filter: all enrichment bases stay unchanged.
create or replace function booking.email_outbox_claim(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  -- Separate SPI statement: observe actual post-trigger statuses, not the caller SELECT snapshot.
  v_rows := booking.email_outbox_claim_base_215(p_limit);
  return (
  select coalesce(jsonb_agg(
    case when z.item->>'kind' = 'payment_link_reminder' then
      (case when exists (
          select 1 from booking.email_outbox e
          join booking.payments p on p.id = e.payment_id
          join booking.orders o on o.id = e.order_id
         where e.id = (z.item->>'id')::bigint
           and p.status = 'pending' and p.provider <> 'manual' and p.external_source is null and o.external_source is null
           and (p.link_expires_at is null or p.link_expires_at > now()))
        then z.item
        else z.item || jsonb_build_object('payment', (coalesce(z.item->'payment', '{}'::jsonb) - 'link_url'))
       end)
      || coalesce((select jsonb_build_object('payment_reminder', jsonb_build_object(
            'n', e.payload -> 'reminder_no', 'kind', e.payload ->> 'reminder_kind',
            'cancel_if_unpaid', coalesce((e.payload ->> 'cancel_if_unpaid')::boolean, false),
            'due_at', e.payload -> 'due_at'))
          from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else case when z.item->>'kind' = 'order_confirmation' then
      z.item || coalesce((
        select jsonb_build_object('order', coalesce(z.item->'order', '{}'::jsonb) || jsonb_build_object(
          'deposit', true,
          'training', jsonb_build_object(
            'course_price', tp.course_price, 'addons_total', tp.addons_total, 'total', tp.total,
            'deposit_paid', tp.deposit_paid, 'remaining', tp.remaining, 'addons', tp.addons,
            'segments', tp.segments)))
          from booking.email_outbox e
          join booking.training_participants tp on tp.order_id = e.order_id
         where e.id = (z.item->>'id')::bigint
         order by tp.id limit 1
      ), '{}'::jsonb)
    else z.item end end
  order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(v_rows) with ordinality as z(item, ord)
  where exists (select 1 from booking.email_outbox e where e.id=(z.item->>'id')::bigint and e.status='sending')
  );
end $$;
