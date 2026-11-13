-- PROD sxbofnuisemspgquoxyv supabase_migrations.schema_migrations version 20261111142016 name booking_voucher_problem_alert (1 lauseketta)
-- booking_voucher_problem_alert (20261111141534)
-- Kumppanilahjakortin lunastuspyyntö ongelmatilaan -> SISÄINEN hälytys henkilökunnalle (booking.notifications_outbox, target 'tapio',
-- topic 'voucher_claim_problem', luetaan notifications_pull/notifications_ack). Asiakkaalle ei lähetetä mitään; _vc_notify_problem ennallaan.
-- 1) trigger voucher_claims -> hälytys kun tila muuttuu problemiksi; ratkeaa automaattisesti kun tila poistuu problemista
-- 2) _vc_resolve: ongelmatilassa resolved_at = null (pyyntö on avoin)
-- 3) voucher_claims_housekeeping: listaa kaikki ongelmapyynnöt, joiden varaus alkaa < 7 vrk (myös menneet), ja varmistaa hälytyksen (dedupe, ei tuplia)
-- Ei koske booking_264:ään eikä sen funktioihin.

-- Hälytyksen sisältö: tilausnumero, ongelmakoodi, myyjä, varauksen alku. EI lahjakoodia.
create or replace function booking._vc_problem_alert_payload(p_claim bigint)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object('claim_id', c.id, 'order_id', c.order_id, 'order_no', o.order_no, 'problem_code', c.problem_code,
           'source', c.source, 'source_label', booking._vc_source_label(c.source), 'flagged_by', c.resolved_by,
           'reservation_id', r.id, 'starts_at', r.starts_at,
           'starts_local', to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
           'days_to_start', case when r.starts_at is null then null else floor(extract(epoch from (r.starts_at - now())) / 86400)::int end,
           'order_status', o.status, 'payment_status', o.payment_status,
           'unpaid', case when o.id is null then null else (booking._order_balance(o.id) ->> 'unpaid')::numeric end,
           'message', 'Kumppanilahjakortin lunastus epäonnistui (' || coalesce(c.problem_code, '?') || '), tilaus #' || coalesce(o.order_no::text, '?')
                      || coalesce(', varaus ' || to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'), '')
                      || '. Varaus on vahvistettu maksamatta: ota yhteyttä asiakkaaseen (uusi koodi tai maksu).')
    from booking.voucher_claims c
    left join booking.orders o on o.id = c.order_id
    left join lateral (select x.id, x.starts_at from booking.reservations x
                        where (x.id = c.reservation_id) or (c.reservation_id is null and x.order_id = c.order_id and x.status in ('pending', 'confirmed'))
                        order by (x.id = c.reservation_id) desc, x.starts_at limit 1) r on true
   where c.id = p_claim
$function$;

-- Jonottaa hälytyksen (yksi per ongelmajakso). Palauttaa true, jos uusi/uudelleen avattu hälytys syntyi.
create or replace function booking._vc_problem_alert(p_claim bigint)
 returns boolean
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_payload jsonb; v_n int;
begin
  if not exists (select 1 from booking.voucher_claims where id = p_claim and status = 'problem') then return false; end if;
  v_payload := booking._vc_problem_alert_payload(p_claim);
  insert into booking.notifications_outbox(topic, target, ref_table, ref_id, dedupe_key, payload)
  values ('voucher_claim_problem', 'tapio', 'voucher_claims', p_claim, 'vcp:' || p_claim, v_payload)
  on conflict (dedupe_key) do update
     set payload = excluded.payload, status = 'new', created_at = now(), acked_at = null, acked_by = null, resolved_at = null, resolved_reason = null
   where booking.notifications_outbox.status = 'resolved';
  get diagnostics v_n = row_count;
  return v_n > 0;
end $function$;

create or replace function booking._vc_problem_alert_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if new.status = 'problem' and (tg_op = 'INSERT' or old.status is distinct from 'problem') then
    perform booking._vc_problem_alert(new.id);
  elsif tg_op = 'UPDATE' and old.status = 'problem' and new.status <> 'problem' then
    update booking.notifications_outbox set status = 'resolved', resolved_at = now(), resolved_reason = 'claim_' || new.status
     where dedupe_key = 'vcp:' || new.id and status <> 'resolved';
  end if;
  return null;
end $function$;

drop trigger if exists voucher_claims_problem_alert on booking.voucher_claims;
create trigger voucher_claims_problem_alert after insert or update of status on booking.voucher_claims
  for each row execute function booking._vc_problem_alert_trg();

CREATE OR REPLACE FUNCTION booking._vc_resolve(p_id bigint, p_status text, p_problem text, p_note text, p_value numeric, p_ref text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; o booking.orders; v_pay jsonb := null; v_note text; v_max int;
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

  if p_status = 'open' then
    -- botti vapauttaa takaisin jonoon (kumppanin sivu ei vastaa yms.) tai henkilökunta avaa ongelman uudelleen
    v_max := coalesce((booking._setting('voucher_claims.max_attempts', '6'::jsonb) #>> '{}')::int, 6);
    if p_by = 'bot' and c.attempts >= v_max then
      v_status := 'problem'; v_problem := 'other'; v_note := concat_ws(' / ', v_note, 'automaattinen: ' || c.attempts || ' yritystä epäonnistui, henkilökunnan tarkistettava');
    end if;
  end if;

  if v_status = 'redeemed' then
    select * into o from booking.orders where id = c.order_id for update;
    v_review := false;
    if booking._order_invoice_locked(o.id) then
      v_review := true; v_note := concat_ws(' / ', v_note, 'tilaus on laskutettu: kumppanilahjakortti lunastettu mutta maksua ei kirjattu');
    elsif o.status in ('pending', 'confirmed') and o.external_source is null then
      v_pay := booking._vc_pay(o, c, p_value);
      if (v_pay ->> 'payment_id') is null then v_review := true; v_note := concat_ws(' / ', v_note, 'tilauksella ei ollut maksettavaa: kumppanilahjakortti lunastettu ilman maksukirjausta'); end if;
    else
      v_review := true; v_note := concat_ws(' / ', v_note, 'tilaus oli ' || o.status || ': kumppanilahjakortti lunastettu mutta maksua ei kirjattu');
    end if;
    update booking.voucher_claims set status = 'redeemed', problem_code = null, voucher_value = coalesce(p_value, voucher_value), amount = coalesce((v_pay ->> 'amount')::numeric, 0),
           payment_id = (v_pay ->> 'payment_id')::bigint, partner_ref = coalesce(v_ref, partner_ref), needs_review = v_review, resolved_at = now(), resolved_by = p_by,
           last_checked_at = now(), notes = concat_ws(E'\n', notes, nullif(to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': ' || coalesce(v_note, 'lunastettu'), '')) where id = c.id;
  elsif v_status = 'problem' then
    update booking.voucher_claims set status = 'problem', problem_code = v_problem, hold_until = null, partner_ref = coalesce(v_ref, partner_ref), resolved_at = null, resolved_by = p_by,   -- booking_voucher_problem_alert: ongelma = avoin (resolved_at null)
           problem_notified_at = null, last_checked_at = now(),
           notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': ongelma ' || v_problem || coalesce(' – ' || v_note, '')) where id = c.id;
    v_notified := booking._vc_notify_problem(c.id);
  elsif v_status = 'cancelled' then
    update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = p_by, last_checked_at = now(),
           notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': peruttu' || coalesce(' – ' || v_note, '')) where id = c.id;
  else  -- open
    update booking.voucher_claims set status = 'open', problem_code = null, hold_until = null, problem_notified_at = null, resolved_at = null, resolved_by = null, last_checked_at = now(),
           notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' ' || p_by || ': palautettu jonoon' || coalesce(' – ' || v_note, '')) where id = c.id;
  end if;
  select * into c from booking.voucher_claims where id = p_id;
  return jsonb_build_object('ok', true, 'claim', booking._vc_json(c, false), 'payment_id', c.payment_id, 'amount', c.amount, 'problem_email_queued', v_notified,
                            'balance', case when c.status = 'redeemed' then booking._order_balance(c.order_id) end);
end $function$;


create or replace function booking.voucher_claims_housekeeping()
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_stale int; v_open3 int; v_oldest numeric; v_due jsonb; v_queued int := 0; v_problem int; r record;
begin
  select count(*) into v_open3 from booking.voucher_claims where status = 'open' and created_at < now() - interval '3 hours';   -- botti ei ole käsitellyt: valvonta
  select count(*), round(max(extract(epoch from (now() - created_at)) / 3600)::numeric, 1) into v_stale, v_oldest from booking.voucher_claims
   where status in ('open', 'processing', 'problem') and created_at < now() - make_interval(hours => booking._vc_remind_hours());
  select count(*) into v_problem from booking.voucher_claims where status = 'problem';
  -- booking_voucher_problem_alert: kaikki ongelmapyynnöt, joiden varaus alkaa alle 7 vrk päästä (tai on jo mennyt), ilman 24 h viivettä.
  -- Hälytys varmistetaan (dedupe vcp:<id>): olemassa olevaa avointa/kuitattua hälytystä ei tuplata.
  for r in
    select c.id from booking.voucher_claims c
     where c.status = 'problem'
       and exists (select 1 from booking.reservations x
                    where ((x.id = c.reservation_id) or (c.reservation_id is null and x.order_id = c.order_id and x.status in ('pending', 'confirmed')))
                      and x.starts_at < now() + interval '7 days')
     order by c.id
  loop
    if booking._vc_problem_alert(r.id) then v_queued := v_queued + 1; end if;
  end loop;
  select coalesce(jsonb_agg(p - 'message' order by p ->> 'starts_at'), '[]'::jsonb) into v_due
    from (select booking._vc_problem_alert_payload(c.id) p from booking.voucher_claims c where c.status = 'problem') q
   where (p ->> 'starts_at') is not null and (p ->> 'starts_at')::timestamptz < now() + interval '7 days';
  return jsonb_build_object('expired_claims', 0, 'open_older_than_3h', v_open3, 'stale_active', v_stale, 'oldest_stale_hours', v_oldest,
                            'problem_claims', v_problem, 'problem_due_7d', v_due, 'problem_due_7d_count', jsonb_array_length(v_due), 'problem_alerts_queued', v_queued);
end $function$;

-- oikeudet: uudet sisäiset funktiot vain omistajalle (ei anon/authenticated/public)
revoke all on function booking._vc_problem_alert_payload(bigint) from public, anon, authenticated, service_role;
revoke all on function booking._vc_problem_alert(bigint) from public, anon, authenticated, service_role;
revoke all on function booking._vc_problem_alert_trg() from public, anon, authenticated, service_role;
-- _vc_resolve: ennallaan {postgres}; housekeeping: ennallaan {postgres, service_role}
revoke all on function booking._vc_resolve(bigint, text, text, text, numeric, text, text) from public, anon, authenticated, service_role;
revoke all on function booking.voucher_claims_housekeeping() from public, anon, authenticated;
grant execute on function booking.voucher_claims_housekeeping() to service_role;

-- Olemassa olevat ongelmapyynnöt: avoimiksi (resolved_at null) ja sisäinen hälytys. Ei asiakasviestejä, tilauksiin ei kosketa.
update booking.voucher_claims set resolved_at = null where status = 'problem' and resolved_at is not null;
select booking._vc_problem_alert(id) from booking.voucher_claims where status = 'problem';
