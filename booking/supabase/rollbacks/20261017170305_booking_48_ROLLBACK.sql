-- ROLLBACK booking_48 → palauttaa booking_47-tilan (48 h pito + housekeeping-vanheneminen).
-- Huom: jo vahvistetut pending-varaukset jäävät vahvistetuiksi; hold_until asetetaan nykyisille aktiivisille pyynnöille now()+48 h (ei-aktiivisille now()).

drop function if exists booking.public_update_voucher_claim_code(uuid, bigint, text, text);
drop function if exists booking.admin_list_voucher_claims(text, text, integer, integer, text);
drop function if exists booking.admin_voucher_claim_summary();
drop function if exists booking.svc_voucher_claim_reminders(integer, integer);
insert into booking.settings(key, value, description, is_public) values ('voucher_claims.hold_hours', '48'::jsonb, 'Lunastuspyynnön / ongelmatilanteen varauksen pitoaika tunteina', false) on conflict (key) do nothing;
CREATE OR REPLACE FUNCTION booking._vc_hold_hours()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select least(greatest(coalesce((booking._setting('voucher_claims.hold_hours', '48'::jsonb) #>> '{}')::int, 48), 1), 720) $function$;

CREATE OR REPLACE FUNCTION booking._vc_extend_hold(p_order bigint, p_until timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n int;
begin
  update booking.reservations set hold_expires_at = greatest(coalesce(hold_expires_at, p_until), p_until)
   where order_id = p_order and status = 'pending' and (hold_expires_at is null or hold_expires_at < p_until);
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_list_voucher_claims(p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

update booking.voucher_claims set hold_until = case when status in ('open', 'processing', 'problem') then now() + interval '48 hours' else now() end where hold_until is null;
alter table booking.voucher_claims alter column hold_until set not null;
comment on column booking.voucher_claims.hold_until is null;
drop index if exists booking.voucher_claims_status_created_idx;
create index if not exists voucher_claims_status_idx on booking.voucher_claims(status, hold_until);
CREATE OR REPLACE FUNCTION booking._vc_json(c booking.voucher_claims, p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'notes', c.notes, 'resolved_at', c.resolved_at, 'resolved_by', c.resolved_by, 'created_at', c.created_at, 'updated_at', c.updated_at) $function$;

CREATE OR REPLACE FUNCTION booking._vc_notify_problem(p_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; v_ok boolean;
begin
  if not booking._gc_flag('voucher_claims.problem_emails_enabled') then return false; end if;
  select * into c from booking.voucher_claims where id = p_id for update;
  if not found or c.status <> 'problem' or c.problem_notified_at is not null or c.problem_code not in ('invalid_code', 'expired_code', 'already_used') or c.hold_until <= now() then return false; end if;
  v_ok := booking._enqueue_email('voucher_claim_problem', c.order_id, null, null, 'vcprob:' || c.id || ':' || extract(epoch from c.resolved_at)::bigint, jsonb_build_object('claim_id', c.id, 'problem_code', c.problem_code));
  if v_ok then update booking.voucher_claims set problem_notified_at = now() where id = c.id; end if;
  return v_ok;
end $function$;

CREATE OR REPLACE FUNCTION booking._vc_resolve(p_id bigint, p_status text, p_problem text, p_note text, p_value numeric, p_ref text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION booking.public_submit_voucher_claim(p_token uuid, p_code text, p_source text, p_order_item_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_order_voucher_claims(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION booking.svc_list_open_voucher_claims(p_limit integer DEFAULT 50, p_mark boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION booking.svc_notify_voucher_claim_problems()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record; n int := 0;
begin
  if not booking._gc_flag('voucher_claims.problem_emails_enabled') then return jsonb_build_object('ok', true, 'enabled', false, 'queued', 0); end if;
  for r in select id from booking.voucher_claims where status = 'problem' and problem_notified_at is null and problem_code in ('invalid_code', 'expired_code', 'already_used') and hold_until > now() order by id loop
    if booking._vc_notify_problem(r.id) then n := n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'enabled', true, 'queued', n);
end $function$;

CREATE OR REPLACE FUNCTION booking.voucher_claims_housekeeping()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_exp int; v_stale int;
begin
  update booking.voucher_claims set status = 'expired', resolved_at = now(), resolved_by = 'system',
         notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' system: pito (hold_until) päättyi')
   where status in ('open', 'processing', 'problem') and hold_until < now();
  get diagnostics v_exp = row_count;
  select count(*) into v_stale from booking.voucher_claims where status = 'open' and created_at < now() - interval '3 hours';   -- botti ei ole käsitellyt: valvonta
  return jsonb_build_object('expired_claims', v_exp, 'open_older_than_3h', v_stale);
end $function$;

drop function if exists booking._vc_keep_reserved(bigint);
drop function if exists booking._vc_remind_hours();
delete from booking.settings where key = 'voucher_claims.remind_after_hours';
revoke all on function booking._vc_hold_hours() from public, anon, authenticated;
revoke all on function booking._vc_extend_hold(bigint, timestamptz) from public, anon, authenticated;
revoke all on function booking.admin_list_voucher_claims(text, text, integer, integer) from public, anon, authenticated;
grant execute on function booking.admin_list_voucher_claims(text, text, integer, integer) to service_role, authenticated;
