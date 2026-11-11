-- booking_280 ROLLBACK: palauttaa admin_refund-, admin_set_reservation_status- ja admin_cancel_reservation(4 arg) -rungot tavu-identtisinä
-- (md5 709d5fd5… / aed4b0d7… / e627951c…) ja poistaa 280:n uudet funktiot. Koko tiedosto yhtenä transaktiona (psql -1).
-- booking_281 on purettava ensin (se korvaa admin_cancel_reservationin 6 argumentin versiolla).
-- Menetetyt lahjakorttiarvot (gift_card_forfeits) ovat kirjanpitotietoa: jos rivejä on, rollback keskeytyy (forward-fix).
set local lock_timeout = '5s';
do $pre$
declare v text; x record;
begin
  if to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean)') is not null then
    raise exception 'rollback booking_280: booking_281 on asennettu; pura 281 ensin. Ei muutoksia.';
  end if;
  for x in select * from (values
      ('booking.admin_refund(bigint,numeric,text,jsonb,boolean)', array['21cdc941bb061856bd368130a08a5704','709d5fd54d877846682571b60c5d21bd']),
      ('booking.admin_set_reservation_status(bigint,text,text)', array['9a63771574d6a03f665078c5895010d5','aed4b0d7e19f7c13d1ac91c28cc0b642'])
    ) t(sig, ok) loop
    v := md5(pg_get_functiondef(to_regprocedure(x.sig)));
    if v is null or not (v = any (x.ok)) then raise exception 'rollback booking_280: % md5 % ei vastaa odotettua. Ei muutoksia.', x.sig, v; end if;
  end loop;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean)')));
  if v is not null and v <> '5664a3cde7b36666711c023e8ce9ba5f' then raise exception 'rollback booking_280: admin_cancel_reservation(5) vieras versio %', v; end if;
  if to_regclass('booking.gift_card_forfeits') is not null and exists (select 1 from booking.gift_card_forfeits) then
    raise exception 'rollback booking_280: gift_card_forfeits sisältää kirjauksia; forward-fix vaaditaan. Ei muutoksia.';
  end if;
end $pre$;

drop function if exists booking.admin_cancel_reservation(bigint, text, boolean, text, boolean);
CREATE OR REPLACE FUNCTION booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text DEFAULT NULL::text, p_refund boolean DEFAULT false, p_refund_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_refund, false) then perform booking._require_permission('payments.refund'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if r.status not in ('pending','confirmed') then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;
  if coalesce(p_refund, false) and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if coalesce(p_refund, false) then v_plan := booking._reservation_refund_plan(r.id); end if;   -- ennen peruutusta (rivit eivät muutu)
  perform booking.admin_set_reservation_status(r.id, 'cancelled', coalesce(nullif(btrim(p_reason), ''), 'henkilökunta'));
  if coalesce(p_refund, false) then
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen peruutus (varaus #' || r.id || ')');
    for x in select * from jsonb_array_elements(v_plan -> 'payments') loop
      v_res := booking.admin_refund((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, v_reason, x -> 'lines', false);
      v_out := v_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'provider', x ->> 'provider', 'amount', (x ->> 'amount')::numeric,
        'refund_id', v_res -> 'refund_id', 'status', v_res ->> 'status', 'receipt_no', v_res -> 'receipt_no');
      v_total := v_total + (x ->> 'amount')::numeric;
    end loop;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', coalesce(p_refund, false), 'refunded_total', v_total));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'balance', booking._order_balance(r.order_id));
end $function$;
revoke all on function booking.admin_cancel_reservation(bigint, text, boolean, text) from public, anon;
grant execute on function booking.admin_cancel_reservation(bigint, text, boolean, text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION booking.admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb DEFAULT NULL::jsonb, p_manual_done boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; v_cap numeric; v_mode text; v_online boolean; v_id bigint; l jsonb; v_pl booking.payment_lines; v_sum numeric := 0; v_full boolean;
        r record; v_total_cap numeric; v_alloc numeric; v_left numeric; v_alloc_json jsonb := '[]'::jsonb; v_status text; rc record; v_n int; v_i int := 0;
        v_gc_sale boolean := false;
begin
  perform booking._require_permission('payments.refund');
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.external_source is not null or pay.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian maksuja ei voi hyvittää tässä'); end if;
  if pay.status = 'refunded' then perform booking._err('already_refunded', 'Maksu on jo hyvitetty kokonaan'); end if;
  if pay.status not in ('paid','partially_refunded') then perform booking._err('refund_not_allowed', 'Vain maksettu maksu voidaan hyvittää'); end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna hyvityksen syy (3–500 merkkiä)'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_cap := pay.amount - pay.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing')), 0);
  if p_amount > v_cap + 0.004 then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_cap)); end if;
  v_online := pay.provider <> 'manual';
  select mode into v_mode from booking.integration_config where key = replace(pay.provider, '_', '');
  if v_online and coalesce(v_mode, 'off') = 'off' then
    if not p_manual_done then perform booking._err('refund_not_allowed', 'Verkkomaksun hyvitys ei ole käytössä – kirjaa hyvitys käsin (vain admin)'); end if;
    if booking.current_staff_role() is distinct from 'admin' then perform booking._err('forbidden', 'Käsinkirjaus verkkomaksulle vaatii admin-roolin'); end if;
  end if;
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0;
  -- lahjakortit (booking_44): lahjakorttien ostomaksu hyvitetään vain kokonaan ja vain käyttämättömille korteille (kortit mitätöidään)
  if exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
     and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled') then
    if not v_full then perform booking._err('gift_card_refund_full_only', 'Lahjakorttien ostomaksu hyvitetään kokonaan (kortit mitätöidään)'); end if;
    if exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status not in ('cancelled', 'pending_payment') and gc.balance < gc.initial_amount) then
      perform booking._err('gift_card_in_use', 'Kortilla on jo käyttöä: ostoa ei voi hyvittää kokonaan (mitätöi kortti hallinnassa ja hyvitä tarvittaessa käsin)');
    end if;
    v_gc_sale := true;
  end if;

  -- rivijako
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'payment_line_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_pl from booking.payment_lines where id = (l ->> 'payment_line_id')::bigint and payment_id = pay.id;
      if not found then perform booking._err('item_not_found', 'Maksun riviä ei löydy'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_pl.amount_gross - v_pl.refunded_gross + 0.004 then perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan'); end if;
      v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', v_pl.id, 'amount', (l ->> 'amount')::numeric);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa hyvityksen summaa'); end if;
  elsif v_full then
    select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', id, 'amount', amount_gross - refunded_gross) order by id), '[]'::jsonb) into v_alloc_json
      from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross <> 0;
  else   -- suhteessa positiivisten rivien hyvitettävään osuuteen
    select coalesce(sum(amount_gross - refunded_gross), 0) into v_total_cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    if v_total_cap < p_amount - 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
    v_left := p_amount; select count(*) into v_n from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    for r in select id, amount_gross - refunded_gross as cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0 order by id loop
      v_i := v_i + 1;
      v_alloc := case when v_i = v_n then v_left else least(round(p_amount * r.cap / v_total_cap, 2), r.cap) end;
      v_alloc := least(v_alloc, r.cap, v_left);
      if v_alloc > 0 then v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', r.id, 'amount', v_alloc); v_left := v_left - v_alloc; end if;
    end loop;
    if v_left > 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
  end if;

  v_status := case when v_online and coalesce(v_mode, 'off') <> 'off' then 'requested' else 'done' end;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_by, done_at)
  values (pay.id, pay.order_id, p_amount, btrim(p_reason), v_status, case when v_online and v_status = 'requested' then pay.provider else 'manual' end,
          case when v_online and v_status = 'done' then 'manual_done' end, v_alloc_json, auth.uid(), case when v_status = 'done' then now() end) returning id into v_id;
  if v_status = 'done' then
    update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
      from jsonb_array_elements(v_alloc_json) x where pl.id = (x ->> 'payment_line_id')::bigint;
    update booking.payments set refunded_amount = refunded_amount + p_amount,
           status = case when refunded_amount + p_amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
    perform booking._sync_placeholder(pay.order_id);
    perform booking._refresh_order_payment(pay.order_id);
    perform booking._on_refund_done(v_id);
    -- lahjakortit (booking_44): ostomaksun hyvitys mitätöi kortit; lahjakorttimaksun hyvitys palautetaan kortille (ei rahana)
    if v_gc_sale then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || v_id || ')'); end if;
    if pay.gift_card_id is not null then perform booking._gc_apply(pay.gift_card_id, p_amount, 'refund', pay.order_id, pay.id, 'Hyvitys kortille: ' || btrim(p_reason)); end if;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'ADMIN_REFUND', null, jsonb_build_object('payment_id', pay.id, 'amount', p_amount, 'reason', p_reason, 'status', v_status));
  select id, receipt_no into rc from booking.receipts where refund_id = v_id;
  return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', v_status, 'balance', booking._order_balance(pay.order_id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_set_reservation_status(p_reservation_id bigint, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations;
begin
  perform booking._require_permission('bookings.manage');
  if p_status not in ('confirmed','cancelled','completed','no_show') then perform booking._err('invalid_status', 'Tila ei sallittu'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  update booking.reservations set
      status = p_status, hold_expires_at = case when p_status = 'confirmed' then null else hold_expires_at end,
      cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
      cancel_reason = case when p_status = 'cancelled' then p_reason else cancel_reason end,
      checkin_at = case when p_status = 'completed' and checkin_at is null then now() else checkin_at end
   where id = p_reservation_id;   -- trigger validoi uudelleenaktivoinnin
  if p_status = 'cancelled' and not exists (select 1 from booking.reservations x where x.order_id = r.order_id and x.status in ('pending','confirmed')) then
    update booking.orders set status = 'cancelled', cancelled_at = now() where id = r.order_id;
  elsif p_status = 'confirmed' then
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), cancelled_at = null where id = r.order_id;
  elsif p_status = 'completed' then
    update booking.orders set status = 'completed' where id = r.order_id and not exists (select 1 from booking.reservations x where x.order_id = r.order_id and x.status in ('pending','confirmed'));
  end if;
  return jsonb_build_object('ok', true);
end $function$;

drop function if exists booking.admin_reservation_cancel_options(bigint);
drop function if exists booking._gc_forfeit_on_cancel(bigint, numeric, bigint, text);
drop function if exists booking._gc_return_to_card(bigint, numeric, jsonb, text, bigint);
drop function if exists booking._gc_keep_allowed(booking.gift_cards);
drop function if exists booking._order_voucher_redeemed(bigint);
drop table if exists booking.gift_card_forfeits;
notify pgrst, 'reload schema';
