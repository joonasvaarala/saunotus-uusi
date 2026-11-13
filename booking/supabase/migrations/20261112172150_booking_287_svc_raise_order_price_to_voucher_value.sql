-- booking_287: Elämyslahjat-arvokortti (yli 12 kk vanha) > tilauksen hinta -> tilauksen hinta nostetaan kortin arvoon,
-- jotta Elämyslahjojen tilitykset täsmäävät (Joonas, Asiakaspalvelun chat 12.11.2026 klo 19.13).
-- Hinnan nosto kuten svc_set_order_price (rivin yksikköhinta/alennus, sama historia ja audit_log), mutta sallii
-- tilauksen kumppanilahjakortin, kun pyyntö on Elämyslahjat ja open/processing. Ei maksulinkkiä, ei sähköpostia.
-- Lunastus kirjataan jälkeenpäin: svc_mark_voucher_claim_redeemed(p_id, p_amount = uusi summa, ..., p_value_card => true).
create or replace function booking.svc_raise_order_price_to_voucher_value(
  p_order_no bigint, p_claim_id bigint, p_new_total numeric, p_note text, p_requested_by text,
  p_actor text default 'Asiakaspalvelu')
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_req text := nullif(btrim(coalesce(p_requested_by, '')), '');
  o booking.orders;
  c booking.voucher_claims;
  it booking.order_items;
  v_n int;
  v_full numeric;
  v_new_line numeric;
  v_new_unit numeric;
  v_new_disc numeric;
  v_old_total numeric;
  v_new_total numeric;
  v_mail_n int;
  v_cancelled bigint[];
  v_ts text := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI');
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if v_req is null then perform booking._err('requested_by_required', 'Anna pyytäjä ja viite (p_requested_by), esim. Joonas t271u 12.11.2026'); end if;
  if char_length(v_note) > 900 or char_length(v_req) > 200 then perform booking._err('invalid_note', 'Muistiinpano enintään 900 ja pyytäjä 200 merkkiä'); end if;
  if p_new_total is null or p_new_total <= 0 or p_new_total > 500 or p_new_total <> round(p_new_total, 2) then
    perform booking._err('invalid_amount', 'Uuden summan pitää olla yli 0 € ja enintään 500 € (enintään 2 desimaalia)');
  end if;
  if p_order_no is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if p_claim_id is null then perform booking._err('not_found', 'Lunastuspyyntöä ei löydy'); end if;

  select * into o from booking.orders where order_no = p_order_no for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;

  select * into c from booking.voucher_claims where id = p_claim_id for update;
  if not found then perform booking._err('not_found', 'Lunastuspyyntöä ei löydy'); end if;
  if c.order_id is distinct from o.id then
    perform booking._err('claim_order_mismatch', 'Lunastuspyyntö ei kuulu tälle tilaukselle');
  end if;
  if c.source is distinct from 'elamyslahjat' then
    perform booking._err('partner_not_allowed', 'Toiminto koskee vain Elämyslahjat-kortteja (pyynnön lähde ' || coalesce(c.source, '?') || ')');
  end if;
  if c.status not in ('open', 'processing') then
    perform booking._err('invalid_state', 'Pyyntö ei ole käsiteltävissä (tila ' || c.status || ')');
  end if;
  if exists (select 1 from booking.voucher_claims x where x.order_id = o.id and x.id <> c.id
              and x.status in ('open', 'processing', 'problem', 'redeemed'))
     or exists (select 1 from booking.vc_difference_payments d where d.order_id = o.id) then
    perform booking._err('other_claims', 'Tilauksella on muita lunastuspyyntöjä tai erotusmaksuja; henkilökunnan tarkistettava');
  end if;

  -- samat tilausehdot kuin svc_set_order_price
  if o.status not in ('pending', 'confirmed') then
    perform booking._err('order_not_changeable', 'Hinnan voi muuttaa vain vahvistetulta tai odottavalta tilaukselta (tila ' || o.status || ')');
  end if;
  if o.external_source is not null then perform booking._err('external_order', 'Tuontitilauksen hintaa ei muuteta'); end if;
  if o.payment_status not in ('unpaid', 'pending') then
    perform booking._err('already_paid', 'Tilaus on maksettu, osittain maksettu, hyvitetty tai laskutettu (' || o.payment_status || ')');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id
              and (p.status in ('paid', 'partially_refunded', 'refunded') or coalesce(p.refunded_amount, 0) > 0)) then
    perform booking._err('already_paid', 'Tilauksella on maksu tai hyvitys; hintaa ei muuteta');
  end if;
  if exists (select 1 from booking.invoices i where i.order_id = o.id and i.voided_at is null) or booking._order_invoice_locked(o.id)
     or exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending' and p.method = 'invoice') then
    perform booking._err('order_invoiced', 'Tilauksella on lasku; hintaa ei muuteta');
  end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending'
              and (p.external_source is not null or (p.provider = 'manual' and exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)))) then
    perform booking._err('pending_payment_conflict', 'Tilauksella on odottava maksu, jota ei voi automaattisesti perua');
  end if;
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

  v_old_total := o.total_gross;
  -- idempotenssi: summa jo kortin arvossa
  if v_old_total = p_new_total then
    return jsonb_build_object('ok', true, 'already', true, 'order_no', o.order_no, 'claim_id', c.id, 'total', o.total_gross,
                              'payment_status', o.payment_status, 'email_queued', false);
  end if;
  if p_new_total <= v_old_total then
    perform booking._err('not_an_increase', format('Uusi summa %s € ei ole suurempi kuin nykyinen %s €', p_new_total, v_old_total));
  end if;

  -- korotettava rivi: pyynnön rivi tai tilauksen ainoa hinnallinen rivi
  if c.order_item_id is not null then
    select * into it from booking.order_items where id = c.order_item_id and order_id = o.id for update;
    if not found then perform booking._err('not_found', 'Pyynnön tilausriviä ei löydy tältä tilaukselta'); end if;
  else
    select count(*) into v_n from booking.order_items where order_id = o.id and kind <> 'discount' and quantity > 0;
    if v_n <> 1 then
      perform booking._err('item_required', 'Tilauksella on ' || v_n || ' riviä ja pyyntö ei osoita riviä; henkilökunnan tarkistettava');
    end if;
    select * into it from booking.order_items where order_id = o.id and kind <> 'discount' and quantity > 0 for update;
  end if;
  if it.kind <> 'reservation' or it.quantity < 1 then perform booking._err('invalid_item', 'Korotettava rivi ei ole varaus'); end if;
  if it.discount_code_id is not null then
    perform booking._err('discount_code_item', 'Rivillä on alennuskoodi; hintaa ei muuteta tällä toiminnolla');
  end if;

  v_new_line := it.line_total_gross + (p_new_total - v_old_total);
  -- sama hinnoittelu kuin svc_set_order_price
  v_full := round(it.unit_price_gross * it.quantity, 2);
  if v_new_line <= v_full then
    v_new_unit := it.unit_price_gross;
    v_new_disc := v_full - v_new_line;
  elsif round(v_new_line / it.quantity, 2) * it.quantity = v_new_line then
    v_new_unit := round(v_new_line / it.quantity, 2);
    v_new_disc := 0;
  else
    perform booking._err('price_not_divisible', format('Korotus %s € ei jakaudu tasan %s kpl:lle', v_new_line, it.quantity));
  end if;

  select count(*) into v_mail_n from booking.email_outbox where order_id = o.id;

  update booking.order_items
     set unit_price_gross = v_new_unit,
         discount_amount = v_new_disc,
         line_total_gross = v_new_line,
         price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('manual_price', jsonb_build_object(
           'previous_unit', it.unit_price_gross, 'previous_discount', it.discount_amount, 'previous_line_total', it.line_total_gross,
           'new_line_total', v_new_line, 'at', now(), 'by', v_actor, 'requested_by', v_req, 'note', v_note,
           'reason', 'elamyslahjat_value_card', 'claim_id', c.id, 'approval', 'Joonas t271u 12.11.2026'))
   where id = it.id;
  if (select line_total_gross from booking.order_items where id = it.id) is distinct from v_new_line then
    perform booking._err('reprice_failed', 'Rivin hinnan muutos ei onnistunut');
  end if;

  update booking.orders
     set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0),
         internal_note = concat_ws(E'\n', internal_note,
           v_ts || ' ' || v_actor || ': hinta nostettu Elämyslahjat-arvokortin arvoon (pyyntö #' || c.id || '), rivi ' || it.product_name || ' '
           || it.line_total_gross || ' € -> ' || v_new_line || ' €, tilaus ' || v_old_total || ' € -> ' || p_new_total
           || ' € (pyytäjä ' || v_req || '): ' || v_note)
   where id = o.id
  returning total_gross into v_new_total;
  if v_new_total is distinct from p_new_total then
    perform booking._err('reprice_failed', format('Tilauksen summa %s € ei vastaa pyydettyä %s €', v_new_total, p_new_total));
  end if;

  -- vanhentuneet verkkomaksulinkit pois (kuten svc_set_order_price); uutta linkkiä ei luoda
  with x as (
    update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'hinta nostettu kortin arvoon (svc_raise_order_price_to_voucher_value), linkki peruttu')
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
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', o.id::text, 'SVC_RAISE_ORDER_PRICE_TO_VOUCHER_VALUE',
          jsonb_build_object('order_no', o.order_no, 'item_id', it.id, 'unit', it.unit_price_gross, 'discount', it.discount_amount,
                             'line_total', it.line_total_gross, 'total', v_old_total, 'claim_id', c.id, 'claim_status', c.status),
          jsonb_build_object('order_no', o.order_no, 'item_id', it.id, 'unit', v_new_unit, 'discount', v_new_disc,
                             'line_total', v_new_line, 'total', v_new_total, 'payment_status', o.payment_status,
                             'cancelled_links', coalesce(to_jsonb(v_cancelled), '[]'::jsonb), 'claim_id', c.id, 'source', c.source,
                             'requested_by', v_req, 'note', v_note, 'actor', v_actor, 'approval', 'Joonas t271u 12.11.2026'));

  return jsonb_build_object('ok', true, 'already', false, 'order_no', o.order_no, 'claim_id', c.id, 'item_id', it.id,
                            'previous_line_total', it.line_total_gross, 'line_total', v_new_line,
                            'previous_total', v_old_total, 'total', v_new_total, 'payment_status', o.payment_status,
                            'cancelled_payment_links', coalesce(to_jsonb(v_cancelled), '[]'::jsonb),
                            'email_queued', false, 'payment_link_created', false,
                            'next_step', format('booking.svc_mark_voucher_claim_redeemed(p_id => %s, p_amount => %s, p_partner_ref => ..., p_note => ..., p_value_card => true)', c.id, v_new_total),
                            'balance', booking._order_balance(o.id));
end
$function$;

revoke all on function booking.svc_raise_order_price_to_voucher_value(bigint, bigint, numeric, text, text, text) from public, anon, authenticated;
grant execute on function booking.svc_raise_order_price_to_voucher_value(bigint, bigint, numeric, text, text, text) to service_role;

comment on function booking.svc_raise_order_price_to_voucher_value(bigint, bigint, numeric, text, text, text) is
  'booking_287: nostaa maksamattoman tilauksen hinnan Elämyslahjat-arvokortin arvoon (open/processing-pyyntö, enintään 500 €). Ei maksulinkkiä eikä sähköpostia. Joonas t271u 12.11.2026.';
