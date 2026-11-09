-- booking_265: Asiakaspalvelu-botin Offerilla-kortin lunastus lunastusarvolla
-- Joonas t250u 9.11.2026 (Asiakaspalvelun chat): "Offerilan korteilla pääsee aina sisään sillä
-- lunastusarvolla eli silloin varauksen arvoksi pitää muuttaa 19."
-- Tilausrivin hinta lasketaan kortin lunastusarvoon (alennuksena, alkuperäinen yksikköhinta säilyy),
-- tilauksen summa = lunastusarvo, ja lunastus kirjataan olemassa olevalla kumppanilahjakorttipolulla
-- (_vc_mark_redeemed -> _vc_resolve -> _vc_pay). EI erotuslinkkiä, EI voucher_difference-viestiä,
-- EI muita sähköposteja (vartija: email_outbox ei saa muuttua). Olemassa olevia funktioita ei muuteta.

CREATE OR REPLACE FUNCTION booking.svc_redeem_partner_voucher_at_value(
  p_claim_id bigint,
  p_redeemed_value numeric,
  p_note text,
  p_code text DEFAULT NULL,
  p_partner_ref text DEFAULT NULL,
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
  v_code text;
  c booking.voucher_claims;
  o booking.orders;
  it booking.order_items;
  v_items int;
  v_old_total numeric;
  v_new_total numeric;
  v_diff numeric;
  v_mail_n int;
  v_links int;
  v_res jsonb;
  v_prev_status text;
  v_code_changed boolean := false;
  v_ts text := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI');
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note), viittaus Joonaksen päätökseen t250u'); end if;
  if char_length(v_note) > 900 then perform booking._err('invalid_note', 'Muistiinpano enintään 900 merkkiä'); end if;
  if p_claim_id is null then perform booking._err('not_found', 'Lunastuspyyntöä ei löydy'); end if;
  if p_redeemed_value is null or p_redeemed_value <= 0 or p_redeemed_value <> round(p_redeemed_value, 2) then
    perform booking._err('invalid_amount', 'Lunastusarvon pitää olla yli 0 € (enintään 2 desimaalia)');
  end if;

  select * into c from booking.voucher_claims where id = p_claim_id for update;
  if not found then perform booking._err('not_found', 'Lunastuspyyntöä ei löydy'); end if;
  if c.source is distinct from 'offerilla' then
    perform booking._err('partner_not_allowed', 'Toiminto koskee vain Offerilla-kortteja (pyynnön lähde ' || coalesce(c.source, '?') || ')');
  end if;

  -- idempotenssi: sama Offerilla-pyyntö jo lunastettu samalla arvolla
  if c.status = 'redeemed' then
    if c.voucher_value = p_redeemed_value and c.payment_id is not null then
      select * into o from booking.orders where id = c.order_id;
      return jsonb_build_object('ok', true, 'already', true, 'claim_id', c.id, 'order_no', o.order_no,
                                'payment_id', c.payment_id, 'amount', c.amount, 'total', o.total_gross,
                                'payment_status', o.payment_status, 'email_queued', false);
    end if;
    perform booking._err('invalid_state', 'Pyyntö on jo lunastettu eri arvolla tai ilman maksukirjausta; henkilökunnan tarkistettava');
  end if;
  if c.status not in ('open', 'processing', 'problem') then
    perform booking._err('invalid_state', 'Pyyntö ei ole käsiteltävissä (tila ' || c.status || ')');
  end if;

  select * into o from booking.orders where id = c.order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.status <> 'confirmed' then
    perform booking._err('order_not_confirmed', 'Vain vahvistetun tilauksen voi kirjata (tila ' || o.status || ')');
  end if;
  if o.external_source is not null then perform booking._err('external_order', 'Tuontitilausta ei voi kirjata tällä toiminnolla'); end if;
  if o.payment_status not in ('unpaid', 'pending') then
    perform booking._err('already_paid', 'Tilaus on jo maksettu, osittain maksettu, hyvitetty tai laskutettu (' || o.payment_status || ')');
  end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu'); end if;
  if exists (select 1 from booking.payments p where p.order_id = o.id
              and (p.status in ('paid', 'partially_refunded', 'refunded') or coalesce(p.refunded_amount, 0) > 0)) then
    perform booking._err('already_paid', 'Tilauksella on jo maksu; kumppanikorttia ei kirjata lunastusarvolla');
  end if;
  -- odottavat maksut, joita _vc_pay ei peruisi (ulkoiset tai rivitetyt manuaaliset, esim. lasku) -> ei kirjata
  if exists (select 1 from booking.payments p where p.order_id = o.id and p.status = 'pending'
              and (p.external_source is not null
                   or (p.provider = 'manual' and exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)))) then
    perform booking._err('pending_payment_conflict', 'Tilauksella on odottava maksu, jota ei voi automaattisesti perua');
  end if;
  if exists (select 1 from booking.voucher_claims x where x.order_id = o.id and x.id <> c.id
              and x.status in ('open', 'processing', 'problem', 'redeemed')) then
    perform booking._err('other_claims', 'Tilauksella on muita lunastuspyyntöjä; henkilökunnan tarkistettava');
  end if;

  -- tilauksella täsmälleen yksi hinnallinen rivi (varaus), joka on pyynnön rivi
  select count(*) into v_items from booking.order_items where order_id = o.id and line_total_gross <> 0;
  if v_items <> 1 then
    perform booking._err('multiple_items', 'Tilauksella pitää olla täsmälleen yksi hinnallinen rivi (nyt ' || v_items || ')');
  end if;
  select * into it from booking.order_items where order_id = o.id and line_total_gross <> 0 for update;
  if c.order_item_id is not null and c.order_item_id <> it.id then
    perform booking._err('multiple_items', 'Pyynnön tilausrivi ei ole tilauksen ainoa hinnallinen rivi');
  end if;
  if it.kind <> 'reservation' then perform booking._err('invalid_item', 'Hinnoiteltava rivi ei ole varaus'); end if;

  v_old_total := o.total_gross;
  if p_redeemed_value > it.line_total_gross or p_redeemed_value > v_old_total then
    perform booking._err('value_exceeds_price', format('Lunastusarvo %s € ylittää tilauksen hinnan %s €', p_redeemed_value, v_old_total));
  end if;

  if p_code is not null then
    v_code := upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g'));
    if v_code !~ '^[A-Z0-9]{6,24}$' then perform booking._err('invalid_code', 'Koodin muoto ei kelpaa'); end if;
  end if;

  select count(*) into v_mail_n from booking.email_outbox where order_id = o.id;
  select count(*) into v_links from booking.payments where order_id = o.id and status = 'pending';

  -- 1) hinta lunastusarvoon (alennuksena; yksikköhinta säilyy)
  v_diff := it.line_total_gross - p_redeemed_value;
  if v_diff > 0 then
    update booking.order_items
       set discount_amount = coalesce(discount_amount, 0) + v_diff,
           line_total_gross = p_redeemed_value,
           price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('partner_voucher_value', jsonb_build_object(
             'claim_id', c.id, 'source', c.source, 'previous_line_total', it.line_total_gross, 'value', p_redeemed_value,
             'at', now(), 'by', v_actor, 'approval', 't250u'))
     where id = it.id;
    if (select line_total_gross from booking.order_items where id = it.id) is distinct from p_redeemed_value then
      perform booking._err('reprice_failed', 'Rivin hinnan muutos ei onnistunut');
    end if;
  end if;
  update booking.orders
     set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0),
         internal_note = concat_ws(E'\n', internal_note,
           v_ts || ' ' || v_actor || ': Offerilla-kortti lunastettu ' || p_redeemed_value || ' €:lla (pyyntö #' || c.id
           || '), tilauksen hinta ' || v_old_total || ' € -> ' || p_redeemed_value || ' €: ' || v_note)
   where id = o.id
  returning total_gross into v_new_total;
  if v_new_total is distinct from p_redeemed_value then
    perform booking._err('reprice_failed', format('Tilauksen summa %s € ei vastaa lunastusarvoa %s €', v_new_total, p_redeemed_value));
  end if;

  -- 2) problem/processing -> open, jotta olemassa oleva lunastuspolku hyväksyy pyynnön (ja koodin korjaus)
  v_prev_status := c.status;
  v_code_changed := (v_code is not null and v_code <> c.code);
  if c.status <> 'open' or v_code_changed then
    update booking.voucher_claims
       set status = 'open', problem_code = null, hold_until = null, resolved_at = null, resolved_by = null,
           code = coalesce(v_code, code),
           notes = concat_ws(E'\n', notes, v_ts || ' bot: ' || v_actor || ' avasi pyynnön Offerilla-lunastukseen lunastusarvolla (aiempi tila '
                   || c.status || case when v_code_changed then ', koodi korjattu' else '' end || ')')
     where id = c.id;
  end if;

  -- 3) olemassa oleva kirjaus: kumppanilahjakorttimaksu (partner_voucher_offerilla), odottavat linkit perutaan,
  --    maksutila päivittyy. Ei erotuslinkkiä (summa = maksettava).
  v_res := booking._vc_mark_redeemed(c.id, p_redeemed_value, p_partner_ref,
             'Offerilla lunastusarvolla ' || p_redeemed_value || ' € (t250u): ' || v_note, 'bot');
  select * into c from booking.voucher_claims where id = c.id;
  select * into o from booking.orders where id = o.id;
  if c.status <> 'redeemed' or c.payment_id is null or c.amount is distinct from p_redeemed_value or o.payment_status <> 'paid' then
    perform booking._err('redeem_failed', format('Lunastus ei kattanut tilausta (tila %s, maksu %s, summa %s, maksutila %s)',
                         c.status, coalesce(c.payment_id::text, '-'), coalesce(c.amount::text, '-'), o.payment_status));
  end if;

  if (select count(*) from booking.email_outbox where order_id = o.id) is distinct from v_mail_n then
    perform booking._err('email_queued', 'Toiminto ei saa jonottaa sähköpostia');
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'booking.voucher_claims', c.id::text, 'SVC_REDEEM_PARTNER_VOUCHER_AT_VALUE',
          jsonb_build_object('order_no', o.order_no, 'claim_status', v_prev_status, 'total', v_old_total, 'order_item_id', it.id,
                             'line_total', it.line_total_gross),
          jsonb_build_object('order_no', o.order_no, 'claim_status', c.status, 'total', v_new_total, 'value', p_redeemed_value,
                             'payment_id', c.payment_id, 'payment_status', o.payment_status, 'pending_payments_before', v_links,
                             'code_changed', v_code_changed,
                             'note', v_note, 'actor', v_actor, 'approval', 't250u 9.11.2026'));

  return jsonb_build_object('ok', true, 'already', false, 'claim_id', c.id, 'order_no', o.order_no,
                            'previous_total', v_old_total, 'total', v_new_total, 'payment_id', c.payment_id, 'amount', c.amount,
                            'payment_status', o.payment_status, 'payment_method', booking._vc_method(c.source),
                            'difference_link', false, 'email_queued', false,
                            'balance', booking._order_balance(o.id));
end
$function$;

comment on function booking.svc_redeem_partner_voucher_at_value(bigint, numeric, text, text, text, text) is
  'booking_265: Offerilla-kortin lunastus lunastusarvolla, tilauksen hinta = lunastusarvo (Joonas t250u 9.11.2026). Ei erotuslinkkiä eikä sähköpostia.';

revoke all on function booking.svc_redeem_partner_voucher_at_value(bigint, numeric, text, text, text, text) from public, anon, authenticated;
grant execute on function booking.svc_redeem_partner_voucher_at_value(bigint, numeric, text, text, text, text) to service_role;
