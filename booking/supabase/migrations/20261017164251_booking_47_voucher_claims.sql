-- ============================================================
-- booking_47_voucher_claims (17.10.2026) – kumppanilahjakorttien (Elämyslahjat, Kokemuskauppa, Kiitoskauppa, Offerilla) lunastuspyynnöt
-- Vain tietokantapuoli. Rollback: booking_47_ROLLBACK.sql
--   1) asetukset: voucher_claims.enabled (false), problem_emails_enabled (false), partner_voucher_accounted (false), hold_hours (48), max_per_order (10), max_attempts (6)
--   2) taulu voucher_claims (RLS, ei suoria oikeuksia; koodi vain RPC:iden kautta, audit-lokissa maskattuna)
--   3) apufunktiot: _vc_mask, _vc_sources, _vc_guess (lähde koodin muodosta), _vc_hold_hours, _vc_extend_hold, _vc_json, _vc_pay, _vc_resolve, _vc_notify_problem
--   4) public_resolve_gift_code, public_submit_voucher_claim, public_get_order_voucher_claims
--   5) admin_list_voucher_claims, admin_get_voucher_claim, admin_resolve_voucher_claim, admin_voucher_claim_stats
--   6) svc_list_open_voucher_claims, svc_resolve_voucher_claim, svc_notify_voucher_claim_problems (service_role / Asiakaspalvelu-botti)
--   7) email_outbox: kind voucher_claim_received / voucher_claim_problem; email_outbox_claim palauttaa voucher_claim-lohkon (koodi maskattuna)
--   8) kirjanpito: _acct_excluded: partner_voucher-maksu ei tuota kuittia/kassaraporttiriviä/outbox-riviä (oletus; kytkin voucher_claims.partner_voucher_accounted)
--   9) orders-trigger (peruttu/vanhentunut tilaus sulkee avoimet pyynnöt), housekeeping + cron (15 min)
-- ============================================================

-- ---------- 1) asetukset ----------
insert into booking.settings(key, value, description, is_public) values
 ('voucher_claims.enabled', 'false'::jsonb, 'Kumppanilahjakorttien lunastuspyynnöt verkossa (public_submit_voucher_claim) päällä. Oletus false kunnes UI ja botti valmiit.', false),
 ('voucher_claims.problem_emails_enabled', 'false'::jsonb, 'Ongelmailmoitus asiakkaalle (voucher_claim_problem) lähtee vain kun true. Oletus false kunnes Joonas on hyväksynyt viestipohjat.', false),
 ('voucher_claims.partner_voucher_accounted', 'false'::jsonb, 'false = partner_voucher-maksu ei tuota kuittia eikä näy kassa-/kirjanpitoraportissa (kuten Johku); true = kuten muut käsin kirjatut maksutavat (kuitti + raportti).', false),
 ('voucher_claims.hold_hours', '48'::jsonb, 'Lunastuspyynnön / ongelmatilanteen varauksen pitoaika tunteina', false),
 ('voucher_claims.max_per_order', '10'::jsonb, 'Aktiivisia lunastuspyyntöjä enintään / tilaus', false),
 ('voucher_claims.max_attempts', '6'::jsonb, 'Botin yrityksiä enintään / pyyntö, jonka jälkeen pyyntö siirtyy tilaan problem/other (henkilökunta)', false)
on conflict (key) do nothing;

-- ---------- 2) taulu ----------
create table booking.voucher_claims (
  id bigint generated always as identity primary key,
  order_id bigint not null references booking.orders(id) on delete cascade,
  reservation_id bigint references booking.reservations(id) on delete set null,
  order_item_id bigint references booking.order_items(id) on delete set null,
  code text not null check (code ~ '^[A-Z0-9]{6,24}$'),                      -- normalisoitu (isot kirjaimet, ei välejä/viivoja); rahanarvoinen: ei näy julkisissa vastauksissa, listoissa eikä audit-lokissa
  source text not null check (source in ('elamyslahjat', 'kokemuskauppa', 'kiitoskauppa', 'offerilla', 'partner_other')),
  source_suggested text check (source_suggested in ('elamyslahjat', 'kokemuskauppa', 'kiitoskauppa', 'offerilla', 'partner_other')),
  status text not null default 'open' check (status in ('open', 'processing', 'redeemed', 'problem', 'cancelled', 'expired')),
  problem_code text check (problem_code in ('invalid_code', 'expired_code', 'already_used', 'other')),
  customer_name text, customer_email text, customer_phone text,
  locale text not null default 'fi',
  hold_until timestamptz not null,
  voucher_value numeric(10,2) check (voucher_value is null or voucher_value >= 0),     -- botin ilmoittama kuponkiarvo
  amount numeric(10,2) check (amount is null or amount >= 0),                            -- tilaukselle kirjattu maksu (partner_voucher)
  payment_id bigint references booking.payments(id) on delete set null,
  partner_ref text,                                                                      -- kumppanin tunniste/kuittaus (ei koodi)
  attempts integer not null default 0,
  last_checked_at timestamptz,
  problem_notified_at timestamptz,
  needs_review boolean not null default false,
  notes text,
  resolved_at timestamptz,
  resolved_by text check (resolved_by in ('bot', 'staff', 'system', 'customer')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint voucher_claims_problem_chk check (status <> 'problem' or problem_code is not null),
  constraint voucher_claims_resolved_chk check ((status in ('open', 'processing')) = (resolved_at is null and resolved_by is null))
);
create unique index voucher_claims_code_active_uq on booking.voucher_claims(code) where status in ('open', 'processing', 'redeemed');
create index voucher_claims_status_idx on booking.voucher_claims(status, hold_until);
create index voucher_claims_order_idx on booking.voucher_claims(order_id);
create index voucher_claims_res_idx on booking.voucher_claims(reservation_id) where reservation_id is not null;
create index voucher_claims_item_idx on booking.voucher_claims(order_item_id) where order_item_id is not null;
create index voucher_claims_pay_idx on booking.voucher_claims(payment_id) where payment_id is not null;
alter table booking.voucher_claims enable row level security;      -- ei policyja: luku/kirjoitus vain SECURITY DEFINER -RPC:illä
revoke all on booking.voucher_claims from public, anon, authenticated;
create trigger voucher_claims_updated before update on booking.voucher_claims for each row execute function booking.set_updated_at();

-- audit: koodi maskattuna (ei selkokielistä rahanarvoista koodia lokiin)
create or replace function booking._vc_audit_trg() returns trigger
language plpgsql security definer set search_path to ''
as $$
declare o jsonb; n jsonb;
begin
  if coalesce(current_setting('booking.skip_audit', true), '') = 'on' and coalesce(booking._jwt_role(), 'service_role') = 'service_role' then return null; end if;
  if tg_op in ('UPDATE', 'DELETE') then o := to_jsonb(old) - 'code' || jsonb_build_object('code_masked', '…' || right(old.code, 4)); end if;
  if tg_op in ('INSERT', 'UPDATE') then n := to_jsonb(new) - 'code' || jsonb_build_object('code_masked', '…' || right(new.code, 4)); end if;
  if tg_op = 'UPDATE' and o = n then return null; end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), tg_table_name, coalesce(n ->> 'id', o ->> 'id'), tg_op, o, n);
  return null;
end $$;
create trigger audit_trg after insert or update or delete on booking.voucher_claims for each row execute function booking._vc_audit_trg();

-- ---------- 3) apufunktiot ----------
create or replace function booking._vc_mask(p_code text) returns text
language sql immutable set search_path to '' as $$ select case when p_code is null then null else '…' || right(p_code, 4) end $$;

create or replace function booking._vc_sources() returns jsonb
language sql immutable set search_path to '' as $$
  select '[{"code":"elamyslahjat","label":"Elämyslahjat","label_en":"Elämyslahjat"},{"code":"kokemuskauppa","label":"Kokemuskauppa","label_en":"Kokemuskauppa"},{"code":"kiitoskauppa","label":"Kiitoskauppa","label_en":"Kiitoskauppa"},{"code":"offerilla","label":"Offerilla","label_en":"Offerilla"}]'::jsonb $$;

-- lähde koodin muodosta (vain aineistosta todetut muodot; Kiitoskaupan muotoa ei tunneta -> ei ehdotusta)
--  Kokemuskauppa: KKnn nnn LLL LLL (32 todettua), Offerilla: OKnn-nnnLLL (95 todettua, kaikki OK19-), Elämyslahjat: 12 merkkiä, vähintään yksi Johkun merkistön (3479ACEFHJKLMNPRTUVWXY) ulkopuolinen (7/7 näytettä)
create or replace function booking._vc_guess(p_norm text) returns jsonb
language sql immutable set search_path to '' as $$
  select case
    when p_norm ~ '^KK[0-9]{5}[A-Z]{6}$' then jsonb_build_object('source', 'kokemuskauppa', 'confidence', 'high')
    when p_norm ~ '^OK[0-9]{5}[A-Z]{3}$' then jsonb_build_object('source', 'offerilla', 'confidence', 'high')
    when p_norm ~ '^[A-Z0-9]{12}$' and p_norm ~ '[^3479ACEFHJKLMNPRTUVWXY]' then jsonb_build_object('source', 'elamyslahjat', 'confidence', 'medium')
    else jsonb_build_object('source', null, 'confidence', null) end $$;

create or replace function booking._vc_source_label(p_source text) returns text
language sql immutable set search_path to '' as $$
  select case p_source when 'elamyslahjat' then 'Elämyslahjat' when 'kokemuskauppa' then 'Kokemuskauppa' when 'kiitoskauppa' then 'Kiitoskauppa' when 'offerilla' then 'Offerilla' else 'Muu kumppani' end $$;

create or replace function booking._vc_hold_hours() returns int
language sql stable security definer set search_path to '' as $$
  select least(greatest(coalesce((booking._setting('voucher_claims.hold_hours', '48'::jsonb) #>> '{}')::int, 48), 1), 720) $$;

-- pitää tilauksen odottavat (pending) varaukset voimassa vähintään p_until asti; vahvistetut varaukset eivät muutu
create or replace function booking._vc_extend_hold(p_order bigint, p_until timestamptz) returns int
language plpgsql security definer set search_path to ''
as $$
declare n int;
begin
  update booking.reservations set hold_expires_at = greatest(coalesce(hold_expires_at, p_until), p_until)
   where order_id = p_order and status = 'pending' and (hold_expires_at is null or hold_expires_at < p_until);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function booking._vc_json(c booking.voucher_claims, p_full boolean default false) returns jsonb
language sql stable security definer set search_path to ''
as $$
  select jsonb_build_object(
    'id', c.id, 'order_id', c.order_id, 'order_no', (select o.order_no from booking.orders o where o.id = c.order_id),
    'reservation_id', c.reservation_id, 'order_item_id', c.order_item_id,
    'source', c.source, 'source_label', booking._vc_source_label(c.source), 'source_suggested', c.source_suggested,
    'code_masked', booking._vc_mask(c.code), 'code', case when p_full then c.code end,
    'status', c.status, 'problem_code', c.problem_code,
    'customer_name', c.customer_name, 'customer_email', c.customer_email, 'customer_phone', c.customer_phone, 'locale', c.locale,
    'hold_until', c.hold_until, 'hours_left', case when c.status in ('open', 'processing', 'problem') then round((extract(epoch from (c.hold_until - now())) / 3600)::numeric, 1) end,
    'voucher_value', c.voucher_value, 'amount', c.amount, 'payment_id', c.payment_id, 'partner_ref', c.partner_ref,
    'attempts', c.attempts, 'last_checked_at', c.last_checked_at, 'problem_notified_at', c.problem_notified_at, 'needs_review', c.needs_review,
    'notes', c.notes, 'resolved_at', c.resolved_at, 'resolved_by', c.resolved_by, 'created_at', c.created_at, 'updated_at', c.updated_at) $$;

-- tilauksen maksu partner_voucher-tavalla (kuten _gc_redeem / admin_record_payment). p_value = kuponkiarvo (null = koko maksamaton osuus); maksu = least(arvo, maksamaton).
create or replace function booking._vc_pay(o booking.orders, c booking.voucher_claims, p_value numeric) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_unpaid numeric; v_amt numeric; v_id bigint; v_it record; v_note text;
begin
  if p_value is not null and (p_value < 0 or p_value <> round(p_value, 2)) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if c.order_item_id is not null then
    select * into v_it from booking._order_uncovered(o.id, false) u where u.item_id = c.order_item_id;
    v_unpaid := least(v_unpaid, coalesce(v_it.remaining, 0));
  end if;
  v_amt := least(coalesce(p_value, v_unpaid), v_unpaid);
  if v_amt <= 0 then return jsonb_build_object('payment_id', null, 'amount', 0); end if;
  v_note := concat_ws(' | ', 'Kumppanin lahjakortti (' || booking._vc_source_label(c.source) || ') ' || booking._vc_mask(c.code), 'pyyntö #' || c.id, c.partner_ref);
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu kumppanilahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, note, created_by)
  values (o.id, 'partner_voucher', 'manual', 'pending', v_amt, v_note, auth.uid()) returning id into v_id;
  if c.order_item_id is not null then
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    values (v_id, v_it.item_id, v_it.description, v_it.kind, case when v_amt = v_it.remaining then v_it.quantity else 1 end, v_amt, v_it.vat_rate);
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;      -- _acct_excluded: ei kuittia / kassaraporttia (oletus)
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  return jsonb_build_object('payment_id', v_id, 'amount', v_amt);
end $$;

-- ongelmailmoitus asiakkaalle: vain jos asetus päällä, pyyntö on problem (invalid/expired/used), ei vielä ilmoitettu ja varaus pidossa
create or replace function booking._vc_notify_problem(p_id bigint) returns boolean
language plpgsql security definer set search_path to ''
as $$
declare c booking.voucher_claims; v_ok boolean;
begin
  if not booking._gc_flag('voucher_claims.problem_emails_enabled') then return false; end if;
  select * into c from booking.voucher_claims where id = p_id for update;
  if not found or c.status <> 'problem' or c.problem_notified_at is not null or c.problem_code not in ('invalid_code', 'expired_code', 'already_used') or c.hold_until <= now() then return false; end if;
  v_ok := booking._enqueue_email('voucher_claim_problem', c.order_id, null, null, 'vcprob:' || c.id || ':' || extract(epoch from c.resolved_at)::bigint, jsonb_build_object('claim_id', c.id, 'problem_code', c.problem_code));
  if v_ok then update booking.voucher_claims set problem_notified_at = now() where id = c.id; end if;
  return v_ok;
end $$;

-- yhteinen käsittely botille (p_by='bot') ja henkilökunnalle (p_by='staff')
create or replace function booking._vc_resolve(p_id bigint, p_status text, p_problem text, p_note text, p_value numeric, p_ref text, p_by text) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare c booking.voucher_claims; o booking.orders; v_pay jsonb := null; v_until timestamptz; v_hours int := booking._vc_hold_hours(); v_note text; v_max int;
        v_status text := p_status; v_problem text := p_problem; v_review boolean; v_notified boolean := false; v_ref text := nullif(left(btrim(coalesce(p_ref, '')), 200), '');
begin
  if p_status not in ('redeemed', 'problem', 'cancelled', 'open') then perform booking._err('invalid_status', 'Tila ei kelpaa (redeemed, problem, cancelled, open)'); end if;
  if p_status = 'problem' and coalesce(p_problem, '') not in ('invalid_code', 'expired_code', 'already_used', 'other') then perform booking._err('invalid_problem_code', 'problem_code: invalid_code, expired_code, already_used tai other'); end if;
  if p_status = 'cancelled' and p_by = 'bot' then perform booking._err('invalid_status', 'Botti ei peruuta pyyntöjä'); end if;
  if p_note is not null and char_length(p_note) > 1000 then perform booking._err('invalid_note', 'Muistiinpano enintään 1000 merkkiä'); end if;
  select * into c from booking.voucher_claims where id = p_id for update;
  if not found then perform booking._err('not_found', 'Lunastuspyyntöä ei löydy'); end if;
  if p_by = 'bot' and c.status not in ('open', 'processing') then perform booking._err('invalid_state', 'Pyyntö ei ole käsiteltävissä (tila ' || c.status || ')'); end if;
  if p_by = 'staff' and c.status not in ('open', 'processing', 'problem') then perform booking._err('invalid_state', 'Pyyntöä ei voi enää muuttaa (tila ' || c.status || ')'); end if;
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_until := c.hold_until;

  if p_status = 'open' then
    -- botti vapauttaa takaisin jonoon (kumppanin sivu ei vastaa yms.) tai henkilökunta avaa ongelman uudelleen
    v_max := coalesce((booking._setting('voucher_claims.max_attempts', '6'::jsonb) #>> '{}')::int, 6);
    if p_by = 'bot' and c.attempts >= v_max then
      v_status := 'problem'; v_problem := 'other'; v_note := concat_ws(' / ', v_note, 'automaattinen: ' || c.attempts || ' yritystä epäonnistui, henkilökunnan tarkistettava');
    elsif p_by = 'staff' then
      v_until := now() + make_interval(hours => v_hours);
    end if;
  end if;
  if v_status = 'problem' then v_until := now() + make_interval(hours => v_hours); end if;

  if v_status = 'redeemed' then
    select * into o from booking.orders where id = c.order_id for update;
    v_review := false;
    if o.status in ('pending', 'confirmed') and o.external_source is null then
      v_pay := booking._vc_pay(o, c, p_value);
      if (v_pay ->> 'payment_id') is null then v_review := true; v_note := concat_ws(' / ', v_note, 'tilauksella ei ollut maksettavaa: kumppanilahjakortti lunastettu ilman maksukirjausta'); end if;
    else
      v_review := true; v_note := concat_ws(' / ', v_note, 'tilaus oli ' || o.status || ': kumppanilahjakortti lunastettu mutta maksua ei kirjattu');
    end if;
    update booking.voucher_claims set status = 'redeemed', problem_code = null, voucher_value = coalesce(p_value, voucher_value), amount = coalesce((v_pay ->> 'amount')::numeric, 0),
           payment_id = (v_pay ->> 'payment_id')::bigint, partner_ref = coalesce(v_ref, partner_ref), needs_review = v_review, resolved_at = now(), resolved_by = p_by,
           last_checked_at = now(), notes = concat_ws(E'\n', notes, nullif(to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': ' || coalesce(v_note, 'lunastettu'), '')) where id = c.id;
  elsif v_status = 'problem' then
    update booking.voucher_claims set status = 'problem', problem_code = v_problem, hold_until = v_until, partner_ref = coalesce(v_ref, partner_ref), resolved_at = now(), resolved_by = p_by,
           problem_notified_at = null, last_checked_at = now(),
           notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': ongelma ' || v_problem || coalesce(' – ' || v_note, '')) where id = c.id;
    perform booking._vc_extend_hold(c.order_id, v_until);
    v_notified := booking._vc_notify_problem(c.id);
  elsif v_status = 'cancelled' then
    update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = p_by, last_checked_at = now(),
           notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': peruttu' || coalesce(' – ' || v_note, '')) where id = c.id;
  else  -- open
    update booking.voucher_claims set status = 'open', problem_code = null, hold_until = v_until, problem_notified_at = null, resolved_at = null, resolved_by = null, last_checked_at = now(),
           notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': palautettu jonoon' || coalesce(' – ' || v_note, '')) where id = c.id;
    if p_by = 'staff' then perform booking._vc_extend_hold(c.order_id, v_until); end if;
  end if;
  select * into c from booking.voucher_claims where id = p_id;
  return jsonb_build_object('ok', true, 'claim', booking._vc_json(c, false), 'payment_id', c.payment_id, 'amount', c.amount, 'problem_email_queued', v_notified,
                            'balance', case when c.status = 'redeemed' then booking._order_balance(c.order_id) end);
end $$;

-- ---------- 4) julkiset RPC:t ----------
-- koodin tunnistus: oma/Johku-kortti (kuten public_check_gift_card) tai tuntematon (+ ehdotus lähteestä koodin muodosta). Rate limit jaettu public_check_gift_card:n kanssa.
create or replace function booking.public_resolve_gift_code(p_code text) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_norm text := booking.gift_code_norm(p_code); r jsonb; g jsonb;
begin
  if char_length(v_norm) < 6 or char_length(v_norm) > 24 then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Tarkista koodi');
  end if;
  r := booking.public_check_gift_card(p_code);
  if r ->> 'ok' = 'true' then return r || jsonb_build_object('kind', 'own'); end if;
  if r ->> 'code' = 'rate_limited' then return r; end if;
  g := booking._vc_guess(v_norm);
  return jsonb_build_object('ok', true, 'kind', 'unknown', 'partner_claims_enabled', booking._gc_flag('voucher_claims.enabled'),
    'suggested_source', g ->> 'source', 'suggestion_confidence', g ->> 'confidence', 'sources', booking._vc_sources());
end $$;

create or replace function booking.public_submit_voucher_claim(p_token uuid, p_code text, p_source text, p_order_item_id bigint default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare o booking.orders; v_norm text := booking.gift_code_norm(p_code); v_src text := lower(btrim(coalesce(p_source, ''))); c booking.voucher_claims; ex booking.voucher_claims; cu booking.customers;
        v_until timestamptz; v_guess jsonb; v_unpaid numeric; v_n int; v_max int; v_res bigint; v_detail text; v_msg text;
begin
  if booking._gc_rl_blocked() then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  if not booking._gc_flag('voucher_claims.enabled') then return jsonb_build_object('ok', false, 'code', 'voucher_claims_disabled', 'message', 'Kumppanilahjakorttien lunastus verkossa ei ole vielä käytössä'); end if;
  if p_token is null or not booking._order_rl('vcsub', p_token, 30, 10) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  begin
    select * into o from booking.orders where public_token = p_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if v_src not in ('elamyslahjat', 'kokemuskauppa', 'kiitoskauppa', 'offerilla') then perform booking._err('invalid_source', 'Valitse lahjakortin myyjä (Elämyslahjat, Kokemuskauppa, Kiitoskauppa tai Offerilla)'); end if;
    if v_norm !~ '^[A-Z0-9]{6,24}$' then perform booking._err('invalid_code', 'Tarkista koodi'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
    if o.status = 'pending' and not exists (select 1 from booking.reservations r where r.order_id = o.id and r.status = 'pending' and r.hold_expires_at > now()) then perform booking._err('order_expired', 'Varaus on vanhentunut'); end if;
    if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia'); end if;
    if exists (select 1 from booking.gift_cards g where g.code = v_norm and g.status not in ('cancelled', 'pending_payment')) then perform booking._err('use_own_card', 'Koodi on oma lahjakortti: käytä lahjakortin lunastusta'); end if;
    if p_order_item_id is not null and not exists (select 1 from booking.order_items oi where oi.id = p_order_item_id and oi.order_id = o.id) then perform booking._err('invalid_item', 'Tilausriviä ei löydy'); end if;
    v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
    if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
    -- sama koodi jo aktiivisena tällä tilauksella -> idempotentti; muulla tilauksella tai jo lunastettu -> virhe
    select * into ex from booking.voucher_claims where code = v_norm and status in ('open', 'processing', 'redeemed') limit 1;
    if found then
      if ex.order_id = o.id and ex.status in ('open', 'processing') then
        perform booking._gc_log('ok');
        return jsonb_build_object('ok', true, 'already', true, 'claim_no', ex.id, 'status', 'open', 'source', ex.source, 'source_label', booking._vc_source_label(ex.source), 'code_masked', booking._vc_mask(ex.code), 'hold_until', ex.hold_until);
      end if;
      perform booking._err('code_already_claimed', 'Tämä koodi on jo käytössä toisella varauksella');
    end if;
    select count(*) into v_n from booking.voucher_claims where order_id = o.id and status in ('open', 'processing', 'problem');
    v_max := coalesce((booking._setting('voucher_claims.max_per_order', '10'::jsonb) #>> '{}')::int, 10);
    if v_n >= v_max then perform booking._err('too_many_claims', 'Liian monta lahjakoodia tilauksella'); end if;
    -- ongelmatilassa oleva pyyntö korvataan uudella koodilla/lähteellä
    update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'customer', notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' customer: korvattu uudella koodilla')
     where order_id = o.id and status = 'problem' and order_item_id is not distinct from p_order_item_id;
    v_until := now() + make_interval(hours => booking._vc_hold_hours());
    v_guess := booking._vc_guess(v_norm);
    select * into cu from booking.customers where id = o.customer_id;
    select r.id into v_res from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed') and r.hidden_at is null order by r.starts_at limit 1;
    insert into booking.voucher_claims(order_id, reservation_id, order_item_id, code, source, source_suggested, customer_name, customer_email, customer_phone, locale, hold_until)
    values (o.id, v_res, p_order_item_id, v_norm, v_src, v_guess ->> 'source', cu.name, cu.email, cu.phone, case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end, v_until) returning * into c;
    perform booking._vc_extend_hold(o.id, v_until);
    perform booking._enqueue_email('voucher_claim_received', o.id, null, null, 'vcrecv:' || c.id, jsonb_build_object('claim_id', c.id));
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    if v_detail in ('invalid_code', 'invalid_source', 'not_found') then perform booking._gc_log('invalid'); end if;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform booking._gc_log('ok');
  return jsonb_build_object('ok', true, 'claim_no', c.id, 'status', 'open', 'source', c.source, 'source_label', booking._vc_source_label(c.source), 'code_masked', booking._vc_mask(c.code),
    'hold_until', c.hold_until, 'source_mismatch', (c.source_suggested is not null and c.source_suggested <> c.source));
end $$;

-- tilaussivun tila: asiakkaan omat pyynnöt (koodi maskattuna, ei sisäisiä muistiinpanoja)
create or replace function booking.public_get_order_voucher_claims(p_token uuid) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare o booking.orders;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('vcget', p_token, 60, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'claims', coalesce((select jsonb_agg(jsonb_build_object('claim_no', c.id, 'source', c.source, 'source_label', booking._vc_source_label(c.source), 'code_masked', booking._vc_mask(c.code),
        'status', c.status, 'public_status', case c.status when 'open' then 'received' when 'processing' then 'received' else c.status end, 'problem_code', case when c.status = 'problem' then c.problem_code end,
        'hold_until', case when c.status in ('open', 'processing', 'problem') then c.hold_until end, 'amount', case when c.status = 'redeemed' then c.amount end, 'created_at', c.created_at) order by c.id)
      from booking.voucher_claims c where c.order_id = o.id and not (c.status = 'cancelled' and c.resolved_by = 'customer')), '[]'::jsonb));
end $$;

-- ---------- 5) hallinta ----------
create or replace function booking.admin_list_voucher_claims(p_status text default null, p_search text default null, p_limit integer default 100, p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_norm text; v_total int; v_rows jsonb;
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if p_status is not null and p_status not in ('open', 'processing', 'redeemed', 'problem', 'cancelled', 'expired', 'active', 'needs_review') then perform booking._err('invalid_status', 'Tuntematon tila'); end if;
  v_norm := case when v_s is null then null else booking.gift_code_norm(v_s) end;
  with f as (
    select c.id, c.status, c.created_at from booking.voucher_claims c join booking.orders o on o.id = c.order_id
     where (p_status is null or (p_status = 'active' and c.status in ('open', 'processing', 'problem')) or (p_status = 'needs_review' and c.needs_review) or (p_status not in ('active', 'needs_review') and c.status = p_status))
       and (v_s is null or c.customer_name ilike '%' || v_s || '%' or c.customer_email ilike '%' || v_s || '%' or o.order_no::text = v_s or c.id::text = v_s
            or (char_length(v_norm) >= 4 and c.code like '%' || v_norm || '%'))
  ), pg as (select id from f order by (status in ('open', 'processing', 'problem')) desc, created_at desc, id desc limit least(greatest(coalesce(p_limit, 100), 1), 500) offset greatest(coalesce(p_offset, 0), 0))
  select (select count(*) from f), coalesce((select jsonb_agg(booking._vc_json(c, false) order by (c.status in ('open', 'processing', 'problem')) desc, c.created_at desc, c.id desc) from booking.voucher_claims c where c.id in (select id from pg)), '[]'::jsonb)
    into v_total, v_rows;
  return jsonb_build_object('ok', true, 'total', v_total, 'claims', v_rows);
end $$;

-- koko koodi vain tässä (henkilökunta, kirjataan audit_logiin REVEAL ilman koodia)
create or replace function booking.admin_get_voucher_claim(p_id bigint) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare c booking.voucher_claims; o booking.orders;
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  select * into c from booking.voucher_claims where id = p_id;
  if not found then perform booking._err('not_found', 'Lunastuspyyntöä ei löydy'); end if;
  select * into o from booking.orders where id = c.order_id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'voucher_claims', c.id::text, 'REVEAL', null, jsonb_build_object('code_masked', booking._vc_mask(c.code)));
  return jsonb_build_object('ok', true, 'claim', booking._vc_json(c, true),
    'order', jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross, 'balance', booking._order_balance(o.id)),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status, 'hold_expires_at', r.hold_expires_at, 'product_name', oi.product_name) order by r.starts_at)
        from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null), '[]'::jsonb),
    'payment', (select jsonb_build_object('id', p.id, 'method', p.method, 'status', p.status, 'amount', p.amount, 'paid_at', p.paid_at, 'note', p.note) from booking.payments p where p.id = c.payment_id),
    'source_guess', booking._vc_guess(c.code), 'sources', booking._vc_sources());
end $$;

create or replace function booking.admin_resolve_voucher_claim(p_id bigint, p_status text, p_problem_code text default null, p_note text default null, p_amount numeric default null, p_partner_ref text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
begin
  perform booking._require_permission('giftcards.manage');
  return booking._vc_resolve(p_id, p_status, p_problem_code, p_note, p_amount, p_partner_ref, 'staff');
end $$;

-- tilasto: näkyy tilastoissa, ei kassaraportin totaleissa
create or replace function booking.admin_voucher_claim_stats(p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare v_from date := coalesce(p_from, date '2000-01-01'); v_to date := coalesce(p_to, date '2999-12-31');
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  return jsonb_build_object('ok', true, 'from', p_from, 'to', p_to, 'basis', 'luontipäivä (Europe/Helsinki); lunastettu = payments.partner_voucher, ei kassaraportin totaleissa',
    'by_source', coalesce((select jsonb_agg(x order by x ->> 'source') from (
        select jsonb_build_object('source', c.source, 'label', booking._vc_source_label(c.source), 'claims', count(*), 'open', count(*) filter (where c.status in ('open', 'processing')),
          'problem', count(*) filter (where c.status = 'problem'), 'redeemed', count(*) filter (where c.status = 'redeemed'), 'cancelled_expired', count(*) filter (where c.status in ('cancelled', 'expired')),
          'redeemed_amount', coalesce(sum(c.amount) filter (where c.status = 'redeemed'), 0), 'needs_review', count(*) filter (where c.needs_review)) x
          from booking.voucher_claims c where (c.created_at at time zone 'Europe/Helsinki')::date between v_from and v_to group by c.source) s), '[]'::jsonb),
    'totals', (select jsonb_build_object('claims', count(*), 'redeemed', count(*) filter (where status = 'redeemed'), 'redeemed_amount', coalesce(sum(amount) filter (where status = 'redeemed'), 0), 'open', count(*) filter (where status in ('open', 'processing')),
          'problem', count(*) filter (where status = 'problem')) from booking.voucher_claims where (created_at at time zone 'Europe/Helsinki')::date between v_from and v_to));
end $$;

-- ---------- 6) botti (service_role) ----------
-- Hakee käsiteltävät (open + jumiin jääneet processing yli 30 min) ja merkitsee ne processing-tilaan (attempts+1) -> päällekkäinen ajo ei käsittele samaa kahdesti. Palauttaa koko koodin.
create or replace function booking.svc_list_open_voucher_claims(p_limit integer default 50, p_mark boolean default true) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_ids bigint[]; v_res jsonb;
begin
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.voucher_claims
     where hold_until > now() and (status = 'open' or (status = 'processing' and coalesce(last_checked_at, created_at) < now() - interval '30 minutes'))
     order by created_at, id limit least(greatest(coalesce(p_limit, 50), 1), 200) for update skip locked) q;
  if p_mark and cardinality(v_ids) > 0 then
    update booking.voucher_claims set status = 'processing', attempts = attempts + 1, last_checked_at = now() where id = any (v_ids);
  end if;
  select coalesce(jsonb_agg(booking._vc_json(c, true) || jsonb_build_object(
      'code_formatted', c.code,
      'order', jsonb_build_object('order_no', o.order_no, 'status', o.status, 'total', o.total_gross, 'unpaid', (booking._order_balance(o.id) ->> 'unpaid')::numeric,
         'first_start', (select min(r.starts_at) from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed')),
         'persons', (select max(r.persons) from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed')),
         'product', (select min(oi.product_name) from booking.order_items oi where oi.order_id = o.id and oi.kind = 'reservation'))) order by c.created_at, c.id), '[]'::jsonb)
    into v_res from booking.voucher_claims c join booking.orders o on o.id = c.order_id where c.id = any (v_ids);
  return jsonb_build_object('ok', true, 'marked', p_mark, 'count', cardinality(v_ids), 'claims', v_res);
end $$;

create or replace function booking.svc_resolve_voucher_claim(p_id bigint, p_status text, p_problem_code text default null, p_note text default null, p_amount numeric default null, p_partner_ref text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$ begin return booking._vc_resolve(p_id, p_status, p_problem_code, p_note, p_amount, p_partner_ref, 'bot'); end $$;

-- kun problem_emails_enabled kytketään päälle: lähettää ilmoitukset ongelmatilaisille (hold voimassa, ei vielä ilmoitettu). Botti kutsuu tuntiajon alussa.
create or replace function booking.svc_notify_voucher_claim_problems() returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare r record; n int := 0;
begin
  if not booking._gc_flag('voucher_claims.problem_emails_enabled') then return jsonb_build_object('ok', true, 'enabled', false, 'queued', 0); end if;
  for r in select id from booking.voucher_claims where status = 'problem' and problem_notified_at is null and problem_code in ('invalid_code', 'expired_code', 'already_used') and hold_until > now() order by id loop
    if booking._vc_notify_problem(r.id) then n := n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'enabled', true, 'queued', n);
end $$;

-- ---------- 7) email_outbox ----------
alter table booking.email_outbox drop constraint email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem'));
CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[]; v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now() order by id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked) q;
  update booking.email_outbox set status = 'sending', locked_at = now(), attempts = attempts + 1 where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', coalesce(nullif(e.payload ->> 'to_email', ''), c.email), 'to_name', coalesce(nullif(e.payload ->> 'to_name', ''), c.name),
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status) order by r.starts_at)
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
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
   where e.id = any (v_ids);
  return v_res;
end $function$;


-- ---------- 8) kirjanpito: partner_voucher ei kassamyyntiä ----------
create or replace function booking._acct_excluded(p_order_id bigint, p_payment_id bigint DEFAULT NULL::bigint) returns boolean
language sql stable security definer set search_path to ''
as $$
  select booking._is_johku_row(p_order_id, p_payment_id)
      or coalesce((select true from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                    where p.id = p_payment_id and (g.accounting_origin = 'johku' or g.vat_treatment = 'at_sale')), false)
      or (not booking._gc_flag('voucher_claims.partner_voucher_accounted')
          and coalesce((select true from booking.payments p where p.id = p_payment_id and p.method = 'partner_voucher'), false))
$$;

-- ---------- 9) tilauksen peruutus/vanheneminen sulkee avoimet pyynnöt; housekeeping ----------
create or replace function booking._vc_orders_trg() returns trigger
language plpgsql security definer set search_path to ''
as $$
begin
  update booking.voucher_claims set status = case when new.status = 'expired' then 'expired' else 'cancelled' end, resolved_at = now(), resolved_by = 'system',
         notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' system: tilaus ' || new.status)
   where order_id = new.id and status in ('open', 'processing', 'problem');
  return null;
end $$;
create trigger orders_vc_close after update of status on booking.orders
  for each row when (new.status in ('cancelled', 'expired') and old.status is distinct from new.status) execute function booking._vc_orders_trg();

create or replace function booking.voucher_claims_housekeeping() returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_exp int; v_stale int;
begin
  update booking.voucher_claims set status = 'expired', resolved_at = now(), resolved_by = 'system',
         notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' system: pito (hold_until) päättyi')
   where status in ('open', 'processing', 'problem') and hold_until < now();
  get diagnostics v_exp = row_count;
  select count(*) into v_stale from booking.voucher_claims where status = 'open' and created_at < now() - interval '3 hours';   -- botti ei ole käsitellyt: valvonta
  return jsonb_build_object('expired_claims', v_exp, 'open_older_than_3h', v_stale);
end $$;

-- ---------- oikeudet ----------
revoke all on function booking._vc_audit_trg() from public, anon, authenticated;
revoke all on function booking._vc_mask(text) from public, anon, authenticated;
revoke all on function booking._vc_sources() from public, anon, authenticated;
revoke all on function booking._vc_guess(text) from public, anon, authenticated;
revoke all on function booking._vc_source_label(text) from public, anon, authenticated;
revoke all on function booking._vc_hold_hours() from public, anon, authenticated;
revoke all on function booking._vc_extend_hold(bigint, timestamptz) from public, anon, authenticated;
revoke all on function booking._vc_json(booking.voucher_claims, boolean) from public, anon, authenticated;
revoke all on function booking._vc_pay(booking.orders, booking.voucher_claims, numeric) from public, anon, authenticated;
revoke all on function booking._vc_notify_problem(bigint) from public, anon, authenticated;
revoke all on function booking._vc_resolve(bigint, text, text, text, numeric, text, text) from public, anon, authenticated;
revoke all on function booking._vc_orders_trg() from public, anon, authenticated;
revoke all on function booking.voucher_claims_housekeeping() from public, anon, authenticated;
revoke all on function booking.public_resolve_gift_code(text) from public, anon, authenticated;
revoke all on function booking.public_submit_voucher_claim(uuid, text, text, bigint) from public, anon, authenticated;
revoke all on function booking.public_get_order_voucher_claims(uuid) from public, anon, authenticated;
revoke all on function booking.admin_list_voucher_claims(text, text, integer, integer) from public, anon, authenticated;
revoke all on function booking.admin_get_voucher_claim(bigint) from public, anon, authenticated;
revoke all on function booking.admin_resolve_voucher_claim(bigint, text, text, text, numeric, text) from public, anon, authenticated;
revoke all on function booking.admin_voucher_claim_stats(date, date) from public, anon, authenticated;
revoke all on function booking.svc_list_open_voucher_claims(integer, boolean) from public, anon, authenticated;
revoke all on function booking.svc_resolve_voucher_claim(bigint, text, text, text, numeric, text) from public, anon, authenticated;
revoke all on function booking.svc_notify_voucher_claim_problems() from public, anon, authenticated;
grant execute on function booking.public_resolve_gift_code(text) to service_role, anon, authenticated;
grant execute on function booking.public_submit_voucher_claim(uuid, text, text, bigint) to service_role, anon, authenticated;
grant execute on function booking.public_get_order_voucher_claims(uuid) to service_role, anon, authenticated;
grant execute on function booking.admin_list_voucher_claims(text, text, integer, integer) to service_role, authenticated;
grant execute on function booking.admin_get_voucher_claim(bigint) to service_role, authenticated;
grant execute on function booking.admin_resolve_voucher_claim(bigint, text, text, text, numeric, text) to service_role, authenticated;
grant execute on function booking.admin_voucher_claim_stats(date, date) to service_role, authenticated;
grant execute on function booking.svc_list_open_voucher_claims(integer, boolean) to service_role;
grant execute on function booking.svc_resolve_voucher_claim(bigint, text, text, text, numeric, text) to service_role;
grant execute on function booking.svc_notify_voucher_claim_problems() to service_role;
grant execute on function booking.voucher_claims_housekeeping() to service_role;

do $$ begin
  if not exists (select 1 from cron.job where jobname = 'booking_voucher_claims_housekeeping') then
    perform cron.schedule('booking_voucher_claims_housekeeping', '*/15 * * * *', 'select booking.voucher_claims_housekeeping()');
  end if;
exception when others then raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
