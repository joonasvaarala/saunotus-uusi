-- ============================================================
-- booking_49_mobilepay_epayment: Vipps MobilePay ePayment API -integraation tietokantaosa (VALMIS, OFF-tilassa)
--  * integration_config: uusi avain 'mobilepay', uusi tila 'test' (vain mobilepay); päällekytkentä vaatii settings.approved_by (Joonaksen lupa)
--  * maksuadapteri (vain service_role): mobilepay_payment_prepare / _event / _lookup / _confirmable / _fail / _fill_customer,
--    mobilepay_refund_claim / _complete / _fail, mobilepay_order_refs
--  * julkinen (anon): public_payment_options(p_token) -> milloin MobilePay-painike tarjotaan
--  * payments.method = 'mobilepay' (jo olemassa), payments.provider = 'mobilepay' (admin_refund hakee tilan avaimella replace(provider,'_','') = 'mobilepay')
--  * ei muuta olemassa olevia funktioita; Johku-tilaukset (external_source) eristetty: ei maksua, ei asiakastietojen täydennystä
-- Rollback: booking_49_ROLLBACK.sql
-- ============================================================

-- ---------- 1) integration_config ----------
alter table booking.integration_config drop constraint integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check check (key in ('resend', 'vismapay', 'procountor', 'mobilepay'));
alter table booking.integration_config drop constraint integration_config_mode_check;
alter table booking.integration_config add constraint integration_config_mode_check check (mode in ('off', 'dry_run', 'live', 'test'));
alter table booking.integration_config add constraint integration_config_test_only_mobilepay check (mode <> 'test' or key = 'mobilepay');
alter table booking.integration_config add constraint integration_config_mobilepay_no_dry_run check (key <> 'mobilepay' or mode <> 'dry_run');

insert into booking.integration_config(key, mode, settings, notes)
values ('mobilepay', 'off', jsonb_build_object('provider', 'vipps_mobilepay', 'currency', 'EUR', 'api', 'ePayment v1', 'test_base_url', 'https://apitest.vipps.no', 'live_base_url', 'https://api.vipps.no'),
        'Vipps MobilePay ePayment. off = ei käytössä; test = apitest.vipps.no (MT-sovellus, testikäyttäjät); live = api.vipps.no. Päällekytkentä vaatii settings.approved_by.')
on conflict (key) do nothing;

create or replace function booking._mobilepay_guard_trg() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.key = 'mobilepay' and new.mode in ('test', 'live') and coalesce(btrim(new.settings ->> 'approved_by'), '') = '' then
    raise exception 'MobilePayta ei voi kytkeä päälle ilman settings.approved_by -merkintää (Joonaksen lupa)' using errcode = 'BK001', detail = 'approval_required';
  end if;
  return new;
end $$;
create trigger integration_config_mobilepay_guard before insert or update of mode, settings on booking.integration_config
  for each row execute function booking._mobilepay_guard_trg();

-- ---------- 2) apufunktiot ----------
create or replace function booking._mobilepay_mode() returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select mode from booking.integration_config where key = 'mobilepay'), 'off')
$$;

-- ---------- 3) mobilepay_payment_prepare ----------
-- Valmistelee MobilePay-maksuyrityksen: luo/uudelleenkäyttää pending-maksun (provider 'mobilepay'), varaa uuden viitteen (reference) ja palauttaa tiedot edge-funktiolle.
-- Syöte: joko p_order_token (orders.public_token; maksetaan koko maksamaton osuus) tai p_link_token (payments.link_token; hallinnan maksulinkki).
-- reference = sauna-o<order_no>-p<payment_id>-a<yritys>  (Vipps: a-zA-Z0-9-, 8–64 merkkiä, uniikki per MSN)
create or replace function booking.mobilepay_payment_prepare(p_order_token uuid default null, p_link_token uuid default null, p_expires_minutes integer default 120)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_mode text := booking._mobilepay_mode(); o booking.orders; pay booking.payments; v_tot numeric; v_unpaid numeric; v_open booking.payments;
  v_super jsonb := '[]'::jsonb; v_raw jsonb; v_mp jsonb; v_att int; v_ref text; v_id bigint; v_exp timestamptz; r record; v_started timestamptz;
begin
  if v_mode = 'off' then perform booking._err('mobilepay_off', 'MobilePay-verkkomaksu ei ole käytössä'); end if;
  if (p_order_token is null) = (p_link_token is null) then perform booking._err('invalid_param', 'Anna joko p_order_token tai p_link_token'); end if;
  if p_expires_minutes is null or p_expires_minutes < 15 or p_expires_minutes > 1440 then perform booking._err('invalid_param', 'Voimassaolo 15–1440 min'); end if;
  if not booking._rate_limit('mpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then perform booking._err('rate_limited', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then perform booking._err('not_found', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  end if;
  if o.external_source is not null then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;       -- Johku-eristys
  if o.status not in ('pending', 'confirmed', 'completed', 'expired') then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;
  if o.currency <> 'EUR' then perform booking._err('unsupported_currency', 'Vain EUR tuettu'); end if;
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;

  if p_link_token is not null then
    if pay.status = 'paid' then perform booking._err('already_paid', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then perform booking._err('payment_not_pending', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider not in ('visma_pay', 'mobilepay') then perform booking._err('payment_not_online', 'Ei verkkomaksu'); end if;
    if pay.provider = 'visma_pay' and pay.provider_ref is not null then perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla'); end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then perform booking._err('link_expired', 'Maksulinkki on vanhentunut'); end if;
    if pay.amount > v_unpaid + 0.004 then perform booking._err('link_stale', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta – pyydä uusi linkki'); end if;
    if pay.provider = 'visma_pay' then   -- asiakas valitsi MobilePayn maksulinkin sivulla: siirretään maksu MobilePaylle
      update booking.payments set provider = 'mobilepay', method = 'mobilepay', note = concat_ws(' | ', note, 'vaihdettu MobilePaylle') where id = pay.id returning * into pay;
    end if;
  else
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then perform booking._err('already_paid', 'Tilaus on jo maksettu'); end if;
      perform booking._err('nothing_to_pay', 'Ei maksettavaa');
    end if;
    if exists (select 1 from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and provider_ref is not null and (link_expires_at is null or link_expires_at > now())) then
      perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'mobilepay' and (link_expires_at is null or link_expires_at > now()) and amount = v_tot
      order by id desc limit 1 for update;
    if found then
      pay := v_open;
    else
      for r in select id, provider_ref, raw from booking.payments where order_id = o.id and status = 'pending' and provider in ('mobilepay', 'visma_pay') for update loop
        if r.provider_ref is not null and coalesce(r.raw -> 'mobilepay' ->> 'last_state', 'CREATED') = 'CREATED' then
          v_super := v_super || jsonb_build_array(r.provider_ref);
        end if;
        update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella MobilePay-maksulla') where id = r.id;
      end loop;
      v_exp := now() + make_interval(mins => p_expires_minutes);
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'mobilepay', 'mobilepay', 'pending', v_tot, o.currency, v_exp, 'MobilePay-verkkomaksu') returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
    end if;
  end if;

  v_raw := coalesce(pay.raw, '{}'::jsonb); v_mp := coalesce(v_raw -> 'mobilepay', '{}'::jsonb);
  v_started := nullif(v_mp ->> 'attempt_started_at', '')::timestamptz;
  -- sama yritys vielä kesken (alle 8 min, Vipps-maksu luotu, ei lopputilaa): käytetään samaa ohjausosoitetta
  if pay.provider_ref is not null and pay.link_url is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' and v_started is not null and v_started > now() - interval '8 minutes' then
    return jsonb_build_object('ok', true, 'reuse', true, 'payment_id', pay.id, 'reference', pay.provider_ref, 'redirect_url', pay.link_url, 'order_no', o.order_no, 'order_token', o.public_token, 'mode', v_mode);
  end if;
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' then
    v_super := v_super || jsonb_build_array(pay.provider_ref);   -- edellinen keskeneräinen yritys perutaan Vippsissä
  end if;
  v_att := coalesce((v_mp ->> 'attempts')::int, 0) + 1;
  v_ref := 'sauna-o' || o.order_no || '-p' || pay.id || '-a' || v_att;
  v_mp := v_mp || jsonb_build_object('attempts', v_att, 'attempt_started_at', now(), 'last_state', null, 'env', v_mode,
                                     'refs', coalesce(v_mp -> 'refs', '[]'::jsonb) || to_jsonb(v_ref));
  update booking.payments set provider_ref = v_ref, provider_status = 'initiating', link_url = null, raw = jsonb_set(v_raw, '{mobilepay}', v_mp, true) where id = pay.id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'reuse', false, 'payment_id', pay.id, 'reference', v_ref, 'attempt', v_att, 'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint,
    'currency', pay.currency, 'order_id', o.id, 'order_no', o.order_no, 'order_token', o.public_token, 'locale', o.locale, 'mode', v_mode, 'superseded', v_super,
    'description', left('Sipoonjoen perinnesauna – tilaus ' || o.order_no, 100),
    'site_base_url', booking._setting('site_base_url', null) #>> '{}', 'order_page_path', booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}');
end $$;

-- ---------- 4) mobilepay_payment_event: tallentaa yrityksen tilan (CREATED/ABORTED/EXPIRED/TERMINATED/AUTHORIZED/create_failed/capture_failed ...) ----------
create or replace function booking.mobilepay_payment_event(p_reference text, p_state text, p_redirect_url text default null, p_detail jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments; v_mp jsonb; v_ev jsonb;
begin
  select * into pay from booking.payments where provider = 'mobilepay' and (provider_ref = p_reference or raw -> 'mobilepay' -> 'refs' ? p_reference) for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'payment_not_found'); end if;
  v_mp := coalesce(pay.raw -> 'mobilepay', '{}'::jsonb);
  v_ev := coalesce(v_mp -> 'events', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'ref', p_reference, 'state', p_state, 'detail', p_detail));
  if jsonb_array_length(v_ev) > 30 then v_ev := (select coalesce(jsonb_agg(e), '[]'::jsonb) from (select e from jsonb_array_elements(v_ev) with ordinality t(e, i) order by i desc limit 30) s); end if;
  if p_reference = pay.provider_ref then
    v_mp := v_mp || jsonb_build_object('last_state', p_state, 'events', v_ev);
    update booking.payments set provider_status = p_state, link_url = coalesce(p_redirect_url, link_url), raw = jsonb_set(coalesce(raw, '{}'::jsonb), '{mobilepay}', v_mp, true) where id = pay.id;
  else
    update booking.payments set raw = jsonb_set(coalesce(raw, '{}'::jsonb), '{mobilepay}', v_mp || jsonb_build_object('events', v_ev), true) where id = pay.id;
  end if;
  return jsonb_build_object('ok', true, 'payment_id', pay.id, 'current', p_reference = pay.provider_ref);
end $$;

-- ---------- 5) mobilepay_payment_lookup ----------
create or replace function booking.mobilepay_payment_lookup(p_reference text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare pay booking.payments; o booking.orders;
begin
  if p_reference is null or p_reference !~ '^sauna-o[0-9]+-p[0-9]+-a[0-9]+$' then return jsonb_build_object('found', false); end if;
  select * into pay from booking.payments where provider = 'mobilepay' and (provider_ref = p_reference or raw -> 'mobilepay' -> 'refs' ? p_reference);
  if not found then return jsonb_build_object('found', false); end if;
  select * into o from booking.orders where id = pay.order_id;
  return jsonb_build_object('found', true, 'payment_id', pay.id, 'status', pay.status, 'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'provider_ref', pay.provider_ref, 'stale', p_reference is distinct from pay.provider_ref, 'order_id', o.id, 'order_no', o.order_no, 'order_status', o.status,
    'order_token', o.public_token, 'env', pay.raw -> 'mobilepay' ->> 'env');
end $$;

-- ---------- 6) mobilepay_payment_confirmable: voiko tilauksen vahvistaa (ennen capturea)? Kokeillaan vahvistus alitapahtumassa ja perutaan se. ----------
create or replace function booking.mobilepay_payment_confirmable(p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments; o booking.orders;
begin
  select * into pay from booking.payments where provider = 'mobilepay' and provider_ref = p_reference for update;
  if not found then return jsonb_build_object('confirmable', false, 'reason', 'payment_not_found'); end if;
  if pay.status = 'paid' then return jsonb_build_object('confirmable', true, 'reason', 'already_paid'); end if;
  if pay.status <> 'pending' then return jsonb_build_object('confirmable', false, 'reason', 'payment_' || pay.status); end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.status in ('cancelled', 'draft') then return jsonb_build_object('confirmable', false, 'reason', 'order_' || o.status); end if;
  begin
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = pay.order_id and status in ('pending', 'expired');
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = pay.order_id;
    raise exception 'mobilepay_probe' using errcode = 'P0001';
  exception
    when sqlstate 'BK001' then return jsonb_build_object('confirmable', false, 'reason', 'slot_lost');
    when exclusion_violation then return jsonb_build_object('confirmable', false, 'reason', 'slot_lost');
    when sqlstate 'P0001' then
      if sqlerrm = 'mobilepay_probe' then return jsonb_build_object('confirmable', true, 'reason', 'ok'); end if;
      raise;
  end;
end $$;

-- ---------- 7) mobilepay_payment_fail: peruuttaa pending-maksun (esim. paikka menetetty ennen capturea) ----------
create or replace function booking.mobilepay_payment_fail(p_reference text, p_status text, p_reason text, p_detail jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments;
begin
  if p_status not in ('failed', 'cancelled') then perform booking._err('invalid_param', 'p_status: failed|cancelled'); end if;
  select * into pay from booking.payments where provider = 'mobilepay' and provider_ref = p_reference for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'payment_not_found'); end if;
  if pay.status <> 'pending' then return jsonb_build_object('ok', true, 'unchanged', true, 'status', pay.status); end if;
  update booking.payments set status = p_status, provider_status = coalesce(p_reason, p_status), note = concat_ws(' | ', note, p_reason),
         raw = jsonb_set(coalesce(raw, '{}'::jsonb), '{mobilepay,fail}', jsonb_build_object('at', now(), 'reason', p_reason, 'detail', p_detail), true) where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  if p_reason = 'slot_lost' then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'MobilePay-maksu peruttiin: aika ei enää vapaana (' || p_reference || '). Asiakkaalle ei veloitettu.' where id = pay.order_id;
  end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

-- ---------- 8) mobilepay_fill_customer: täydentää asiakkaan puuttuvat tiedot Vippsin profiilista (ei ylikirjoita olemassa olevaa) ----------
create or replace function booking.mobilepay_fill_customer(p_payment_id bigint, p_name text, p_email text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pay booking.payments; o booking.orders; c booking.customers; v_filled text[] := '{}'; v_email text := lower(nullif(btrim(coalesce(p_email, '')), '')); v_phone text; v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  select * into pay from booking.payments where id = p_payment_id and provider = 'mobilepay';
  if not found then return jsonb_build_object('ok', false, 'code', 'payment_not_found'); end if;
  select * into o from booking.orders where id = pay.order_id;
  if o.external_source is not null or o.customer_id is null then return jsonb_build_object('ok', true, 'filled', '[]'::jsonb, 'skipped', 'order'); end if;   -- Johku-eristys
  select * into c from booking.customers where id = o.customer_id for update;
  if not found or c.anonymized_at is not null or c.external_source is not null then return jsonb_build_object('ok', true, 'filled', '[]'::jsonb, 'skipped', 'customer'); end if;
  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_phone := case when char_length(v_phone) between 8 and 15 then '+' || v_phone end;
  if v_email is not null and char_length(v_email) <= 200 and booking._valid_email(v_email) and coalesce(btrim(c.email), '') = '' then
    update booking.customers set email = v_email where id = c.id; v_filled := array_append(v_filled, 'email'::text);
  end if;
  if v_phone is not null and coalesce(btrim(c.phone), '') = '' then
    update booking.customers set phone = v_phone where id = c.id; v_filled := array_append(v_filled, 'phone'::text);
  end if;
  if v_name is not null and char_length(v_name) <= 200 and coalesce(btrim(c.name), '') = '' then
    update booking.customers set name = v_name where id = c.id; v_filled := array_append(v_filled, 'name'::text);
  end if;
  if array_length(v_filled, 1) > 0 then
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (null, 'service_role', 'customers', c.id::text, 'MOBILEPAY_PROFILE_FILL', null, jsonb_build_object('payment_id', pay.id, 'order_id', o.id, 'fields', to_jsonb(v_filled)));
  end if;
  return jsonb_build_object('ok', true, 'filled', to_jsonb(v_filled));
end $$;

-- ---------- 9) hyvitykset ----------
-- admin_refund luo rivin status='requested', provider='mobilepay' kun mobilepay.mode <> 'off'. Tämä varaa rivit käsittelyyn (requested -> processing; yli 10 min jumissa ollut processing otetaan uudelleen).
create or replace function booking.mobilepay_refund_claim(p_refund_id bigint default null, p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  if booking._mobilepay_mode() = 'off' then return jsonb_build_object('ok', true, 'claimed', '[]'::jsonb, 'mode', 'off'); end if;
  with c as (
    select f.id from booking.refunds f where f.provider = 'mobilepay' and (p_refund_id is null or f.id = p_refund_id)
       and (f.status = 'requested' or (f.status = 'processing' and f.updated_at < now() - interval '10 minutes'))   -- jumiin jäänyt käsittely otetaan uudelleen (sama Idempotency-Key Vippsissä)
     order by f.id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked),
  u as (
    update booking.refunds f set status = 'processing', provider_status = 'processing' from c where f.id = c.id returning f.*)
  select coalesce(jsonb_agg(jsonb_build_object('refund_id', u.id, 'payment_id', u.payment_id, 'amount', u.amount, 'amount_minor', round(u.amount * 100)::bigint, 'refunded_minor', round(p.refunded_amount * 100)::bigint,
           'reference', p.provider_ref, 'currency', p.currency, 'payment_status', p.status) order by u.id), '[]'::jsonb) into v_rows
    from u join booking.payments p on p.id = u.payment_id;
  return jsonb_build_object('ok', true, 'claimed', v_rows, 'mode', booking._mobilepay_mode());
end $$;

create or replace function booking.mobilepay_refund_complete(p_refund_id bigint, p_provider_refund_id text, p_raw jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds; pay booking.payments; v_full boolean; v_gc boolean;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'mobilepay' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  if rf.status not in ('requested', 'processing') then perform booking._err('refund_not_pending', 'Hyvitys ei ole käsiteltävänä'); end if;
  select * into pay from booking.payments where id = rf.payment_id for update;
  v_full := abs(rf.amount - pay.amount) < 0.005 and pay.refunded_amount = 0;
  v_gc := exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
          and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled');
  update booking.refunds set status = 'done', provider_status = 'refunded', provider_refund_id = p_provider_refund_id, raw = coalesce(p_raw, raw), done_at = now() where id = rf.id;
  update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
    from jsonb_array_elements(coalesce(rf.lines, '[]'::jsonb)) x where pl.id = (x ->> 'payment_line_id')::bigint;
  update booking.payments set refunded_amount = refunded_amount + rf.amount,
         status = case when refunded_amount + rf.amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
  perform booking._sync_placeholder(pay.order_id);
  perform booking._refresh_order_payment(pay.order_id);
  perform booking._on_refund_done(rf.id);
  if v_gc and v_full then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || rf.id || ')'); end if;
  return jsonb_build_object('ok', true, 'refund_id', rf.id);
end $$;

create or replace function booking.mobilepay_refund_fail(p_refund_id bigint, p_error jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rf booking.refunds;
begin
  select * into rf from booking.refunds where id = p_refund_id and provider = 'mobilepay' for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status not in ('requested', 'processing') then return jsonb_build_object('ok', true, 'unchanged', true, 'status', rf.status); end if;
  update booking.refunds set status = 'failed', provider_status = 'failed', raw = jsonb_build_object('error', p_error, 'at', now()) where id = rf.id;
  return jsonb_build_object('ok', true, 'status', 'failed');
end $$;

-- ---------- 9b) mobilepay_order_refs: tilaussivun "tarkista maksun tila" (paluu Vipps-sovelluksesta) ----------
-- Palauttaa tilauksen keskeneräisten MobilePay-maksujen nykyiset viitteet; edge (mobilepay-notify, action=reconcile) hakee niiden tilan Vippsistä.
create or replace function booking.mobilepay_order_refs(p_order_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders;
begin
  if p_order_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._rate_limit('mprefs:' || p_order_token::text, 40, interval '10 minutes') then return jsonb_build_object('ok', false, 'code', 'rate_limited'); end if;
  select * into o from booking.orders where public_token = p_order_token;
  if not found or o.external_source is not null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'mode', booking._mobilepay_mode(), 'payment_status', o.payment_status,
    'refs', coalesce((select jsonb_agg(p.provider_ref order by p.id) from booking.payments p
                       where p.order_id = o.id and p.provider = 'mobilepay' and p.status = 'pending' and p.provider_ref is not null
                         and p.provider_status is distinct from 'initiating'), '[]'::jsonb));
end $$;

-- ---------- 10) julkinen: public_payment_options ----------
-- Koodarin UI: kutsu tilaussivulla / varauksen jälkeen. methods on tyhjä kun mobilepay.mode='off'.
-- mode='test' -> methods[].test=true: ÄLÄ näytä painiketta julkisella tuotantosivulla, vain testisivustolla.
create or replace function booking.public_payment_options(p_token uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_mode text := booking._mobilepay_mode(); o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
begin
  if v_mode <> 'off' then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mode = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_mode <> 'off' and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004;
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending);
    if not v_can then v_methods := '[]'::jsonb; end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_mode <> 'off', 'methods', v_methods, 'order', v_order);
end $$;

-- ---------- 11) oikeudet ----------
revoke all on function booking._mobilepay_guard_trg() from public, anon, authenticated;
revoke all on function booking._mobilepay_mode() from public, anon, authenticated;
revoke all on function booking.mobilepay_payment_prepare(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function booking.mobilepay_payment_event(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function booking.mobilepay_payment_lookup(text) from public, anon, authenticated;
revoke all on function booking.mobilepay_payment_confirmable(text) from public, anon, authenticated;
revoke all on function booking.mobilepay_payment_fail(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function booking.mobilepay_fill_customer(bigint, text, text, text) from public, anon, authenticated;
revoke all on function booking.mobilepay_refund_claim(bigint, integer) from public, anon, authenticated;
revoke all on function booking.mobilepay_refund_complete(bigint, text, jsonb) from public, anon, authenticated;
revoke all on function booking.mobilepay_refund_fail(bigint, jsonb) from public, anon, authenticated;
revoke all on function booking.mobilepay_order_refs(uuid) from public, anon, authenticated;
revoke all on function booking.public_payment_options(uuid) from public, anon, authenticated;
grant execute on function booking._mobilepay_mode() to service_role;
grant execute on function booking.mobilepay_payment_prepare(uuid, uuid, integer) to service_role;
grant execute on function booking.mobilepay_payment_event(text, text, text, jsonb) to service_role;
grant execute on function booking.mobilepay_payment_lookup(text) to service_role;
grant execute on function booking.mobilepay_payment_confirmable(text) to service_role;
grant execute on function booking.mobilepay_payment_fail(text, text, text, jsonb) to service_role;
grant execute on function booking.mobilepay_fill_customer(bigint, text, text, text) to service_role;
grant execute on function booking.mobilepay_refund_claim(bigint, integer) to service_role;
grant execute on function booking.mobilepay_refund_complete(bigint, text, jsonb) to service_role;
grant execute on function booking.mobilepay_refund_fail(bigint, jsonb) to service_role;
grant execute on function booking.mobilepay_order_refs(uuid) to service_role;
grant execute on function booking.public_payment_options(uuid) to service_role, anon, authenticated;
