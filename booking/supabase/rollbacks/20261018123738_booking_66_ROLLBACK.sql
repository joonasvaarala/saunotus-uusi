-- Rollback booking_66: palauttaa nimen pienellä p:llä (Resend from + MobilePay-kuvaus).
set local lock_timeout = '5s';
update booking.integration_config set settings = jsonb_set(settings, '{from}', to_jsonb(replace(settings ->> 'from', 'Sipoonjoen Perinnesauna', 'Sipoonjoen perinnesauna'))) where key = 'resend' and settings ->> 'from' like '%Sipoonjoen Perinnesauna%';
CREATE OR REPLACE FUNCTION booking.mobilepay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid, p_expires_minutes integer DEFAULT 120)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_not_payable', 'Alustavaa varausta ei makseta ennen vahvistusta'); end if;
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

  perform booking._checkout_extend_hold(o.id);    -- booking_53: MobilePay-maksu alkaa -> paikka pysyy varattuna lopputulokseen asti (katto: checkout_mobilepay_max_wait_minutes)
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
end $function$;
