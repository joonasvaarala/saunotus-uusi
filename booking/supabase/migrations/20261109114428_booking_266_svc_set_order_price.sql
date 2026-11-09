-- booking_266: Asiakaspalvelu-botin tilausrivin hinnanmuutos svc_set_order_price
-- Joonas t252u 9.11.2026 (Asiakaspalvelun chat): "Joo näissä offerilan tapauksissa sulla pitää olla pysyvä lupa tehdä tuo
-- hinnan muutos ja pyynnöstäni kaikkiin muihinkin tilauksiin aina"
-- Vain maksamattomat (unpaid/pending) vahvistetut tai odottavat tilaukset. Hinta = rivin uusi kokonaishinta (sis. ALV).
-- Lasku: alennuksena (yksikköhinta säilyy). Nosto: ensin alennus pois, sen yli vain jos uusi hinta jakautuu tasan määrälle.
-- Odottavat verkkomaksulinkit perutaan (muistutukset pysähtyvät payments_reminder_stop_trg:llä), manuaaliset
-- paikkaajat (pay_later) päivitetään _sync_placeholder-funktiolla. EI uutta linkkiä, EI sähköpostia
-- (vartija: email_outbox ei saa kasvaa). Uusi linkki: booking.svc_create_payment_link. Olemassa olevia funktioita ei muuteta.

CREATE OR REPLACE FUNCTION booking.svc_set_order_price(
  p_order_no bigint,
  p_new_price numeric,
  p_note text,
  p_requested_by text,
  p_item_id bigint DEFAULT NULL,
  p_actor text DEFAULT 'Asiakaspalvelu'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_req text := nullif(btrim(coalesce(p_requested_by, '')), '');
  o booking.orders;
  it booking.order_items;
  v_n int;
  v_full numeric;
  v_new_unit numeric;
  v_new_disc numeric;
  v_old_total numeric;
  v_new_total numeric;
  v_mail_n int;
  v_cancelled bigint[];
  v_ts text := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI');
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if v_req is null then perform booking._err('requested_by_required', 'Anna pyytäjä ja viite (p_requested_by), esim. Joonas t252u'); end if;
  if char_length(v_note) > 900 or char_length(v_req) > 200 then perform booking._err('invalid_note', 'Muistiinpano enintään 900 ja pyytäjä 200 merkkiä'); end if;
  if p_new_price is null or p_new_price < 0 or p_new_price > 10000 or p_new_price <> round(p_new_price, 2) then
    perform booking._err('invalid_amount', 'Uuden hinnan pitää olla 0–10000 € (enintään 2 desimaalia)');
  end if;
  if p_order_no is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;

  select * into o from booking.orders where order_no = p_order_no for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.status not in ('pending', 'confirmed') then
    perform booking._err('order_not_changeable', 'Hinnan voi muuttaa vain vahvistetulta tai odottavalta tilaukselta (tila ' || o.status || ')');
  end if;
  if o.external_source is not null then perform booking._err('external_order', 'Tuontitilauksen hintaa ei muuteta'); end if;
  if o.payment_status not in ('unpaid', 'pending') then
    perform booking._err('already_paid', 'Tilaus on maksettu, osittain maksettu, hyvitetty tai laskutettu (' || o.payment_status || '); hyvitykset ja lisäveloitukset eivät kuulu tähän toimintoon');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id
              and (p.status in ('paid', 'partially_refunded', 'refunded') or coalesce(p.refunded_amount, 0) > 0)) then
    perform booking._err('already_paid', 'Tilauksella on maksu tai hyvitys; hintaa ei muuteta');
  end if;
  if exists (select 1 from booking.invoices i where i.order_id = o.id and i.voided_at is null) or booking._order_invoice_locked(o.id)
     or exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.method = 'invoice') then
    perform booking._err('order_invoiced', 'Tilauksella on lasku; hintaa ei muuteta');
  end if;
  if exists (select 1 from booking.voucher_claims c where c.order_id = o.id and c.status in ('open', 'processing', 'problem', 'redeemed'))
     or exists (select 1 from booking.vc_difference_payments d where d.order_id = o.id) then
    perform booking._err('voucher_order', 'Tilauksella on kumppanilahjakortti; käytä Offerilla-tapauksissa svc_redeem_partner_voucher_at_value');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending'
              and (p.external_source is not null or (p.provider = 'manual' and exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)))) then
    perform booking._err('pending_payment_conflict', 'Tilauksella on odottava maksu, jota ei voi automaattisesti perua');
  end if;
  -- maksu kesken: aloitettu MobilePay tai alle 2 h sitten aloitettu verkkomaksuyritys
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.provider <> 'manual' and p.provider_ref is not null
              and (p.provider = 'mobilepay'
                   or (coalesce(p.provider_status, '') not in ('failed', 'cancelled') and p.updated_at > now() - interval '2 hours'))) then
    perform booking._err('payment_in_progress', 'Asiakkaan verkkomaksu on kesken; yritä myöhemmin uudelleen');
  end if;
  if exists (select 1 from booking.order_items oi where oi.order_id = o.id and (oi.kind = 'gift_card' or oi.gift_card_id is not null))
     or exists (select 1 from booking.gift_cards g where g.purchase_order_id = o.id)
     or exists (select 1 from booking.order_items oi join kb.products kp on kp.id = oi.product_id where oi.order_id = o.id and kp.category = 'season_card')
     or exists (select 1 from booking.reservations r where r.order_id = o.id and r.annual_card_id is not null)
     or exists (select 1 from booking.training_participants t where t.order_id = o.id) then
    perform booking._err('order_type_not_supported', 'Lahjakortti-, vuosikortti- ja kurssitilausten hintaa ei muuteta tällä toiminnolla');
  end if;

  if p_item_id is null then
    select count(*) into v_n from booking.order_items where order_id = o.id and kind <> 'discount' and quantity > 0;
    if v_n <> 1 then
      perform booking._err('item_required', 'Tilauksella on ' || v_n || ' riviä; anna p_item_id (' ||
        coalesce((select string_agg(id || ' ' || product_name || ' ' || line_total_gross || ' €', ', ' order by id)
                    from booking.order_items where order_id = o.id and kind <> 'discount'), '-') || ')');
    end if;
    select * into it from booking.order_items where order_id = o.id and kind <> 'discount' and quantity > 0 for update;
  else
    select * into it from booking.order_items where id = p_item_id and order_id = o.id for update;
    if not found then perform booking._err('not_found', 'Riviä ei löydy tältä tilaukselta'); end if;
  end if;
  if it.kind in ('discount', 'gift_card') or it.quantity < 1 then perform booking._err('invalid_item', 'Tämän rivin hintaa ei voi muuttaa'); end if;
  if it.discount_code_id is not null then
    perform booking._err('discount_code_item', 'Rivillä on alennuskoodi; hintaa ei muuteta tällä toiminnolla');
  end if;

  -- idempotenssi
  if it.line_total_gross = p_new_price then
    return jsonb_build_object('ok', true, 'already', true, 'order_no', o.order_no, 'item_id', it.id, 'line_total', it.line_total_gross,
                              'total', o.total_gross, 'payment_status', o.payment_status, 'email_queued', false);
  end if;
  if p_new_price = 0 and o.status <> 'confirmed' then
    perform booking._err('zero_requires_confirmed', '0 € hinta vain vahvistetulle tilaukselle');
  end if;

  v_full := round(it.unit_price_gross * it.quantity, 2);
  if p_new_price <= v_full then
    v_new_unit := it.unit_price_gross;
    v_new_disc := v_full - p_new_price;
  elsif round(p_new_price / it.quantity, 2) * it.quantity = p_new_price then
    v_new_unit := round(p_new_price / it.quantity, 2);
    v_new_disc := 0;
  else
    perform booking._err('price_not_divisible', format('Korotus %s € ei jakaudu tasan %s kpl:lle; valitse hinta, joka jakautuu tasan', p_new_price, it.quantity));
  end if;

  select count(*) into v_mail_n from booking.email_outbox where order_id = o.id;
  v_old_total := o.total_gross;

  update booking.order_items
     set unit_price_gross = v_new_unit,
         discount_amount = v_new_disc,
         line_total_gross = p_new_price,
         price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('manual_price', jsonb_build_object(
           'previous_unit', it.unit_price_gross, 'previous_discount', it.discount_amount, 'previous_line_total', it.line_total_gross,
           'new_line_total', p_new_price, 'at', now(), 'by', v_actor, 'requested_by', v_req, 'note', v_note))
   where id = it.id;
  if (select line_total_gross from booking.order_items where id = it.id) is distinct from p_new_price then
    perform booking._err('reprice_failed', 'Rivin hinnan muutos ei onnistunut');
  end if;

  update booking.orders
     set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0),
         internal_note = concat_ws(E'\n', internal_note,
           v_ts || ' ' || v_actor || ': hinta muutettu, rivi ' || it.product_name || ' ' || it.line_total_gross || ' € -> ' || p_new_price
           || ' € (pyytäjä ' || v_req || '): ' || v_note)
   where id = o.id
  returning total_gross into v_new_total;
  if v_new_total < 0 then perform booking._err('reprice_failed', 'Tilauksen summa ei voi olla negatiivinen'); end if;

  -- vanhentuneet verkkomaksulinkit pois (sama ehto kuin _create_link_payment), manuaaliset paikkaajat seuraavat summaa
  with x as (
    update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'hinta muutettu (svc_set_order_price), linkki peruttu')
     where order_id = o.id and status = 'pending'
       and (provider = 'montonio' or provider = 'visma_pay' or (provider = 'mobilepay' and provider_ref is null))
    returning id)
  select array_agg(id order by id) into v_cancelled from x;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  select * into o from booking.orders where id = o.id;

  if (select count(*) from booking.email_outbox where order_id = o.id) is distinct from v_mail_n then
    perform booking._err('email_queued', 'Hinnanmuutos ei saa jonottaa sähköpostia');
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', o.id::text, 'SVC_SET_ORDER_PRICE',
          jsonb_build_object('order_no', o.order_no, 'item_id', it.id, 'unit', it.unit_price_gross, 'discount', it.discount_amount,
                             'line_total', it.line_total_gross, 'total', v_old_total),
          jsonb_build_object('order_no', o.order_no, 'item_id', it.id, 'unit', v_new_unit, 'discount', v_new_disc,
                             'line_total', p_new_price, 'total', v_new_total, 'payment_status', o.payment_status,
                             'cancelled_links', coalesce(to_jsonb(v_cancelled), '[]'::jsonb),
                             'requested_by', v_req, 'note', v_note, 'actor', v_actor));

  return jsonb_build_object('ok', true, 'already', false, 'order_no', o.order_no, 'item_id', it.id,
                            'previous_line_total', it.line_total_gross, 'line_total', p_new_price,
                            'previous_total', v_old_total, 'total', v_new_total, 'payment_status', o.payment_status,
                            'cancelled_payment_links', coalesce(to_jsonb(v_cancelled), '[]'::jsonb),
                            'needs_new_link', (coalesce(array_length(v_cancelled, 1), 0) > 0 and v_new_total > 0),
                            'new_link_function', 'booking.svc_create_payment_link(p_order_no, p_note)',
                            'email_queued', false, 'balance', booking._order_balance(o.id));
end
$function$;

comment on function booking.svc_set_order_price(bigint, numeric, text, text, bigint, text) is
  'booking_266: Asiakaspalvelu-botin tilausrivin hinnanmuutos Joonaksen pyynnöstä (t252u 9.11.2026). Vain maksamattomat tilaukset; peruu vanhat verkkomaksulinkit; ei uutta linkkiä eikä sähköpostia.';

revoke all on function booking.svc_set_order_price(bigint, numeric, text, text, bigint, text) from public, anon, authenticated;
grant execute on function booking.svc_set_order_price(bigint, numeric, text, text, bigint, text) to service_role;
