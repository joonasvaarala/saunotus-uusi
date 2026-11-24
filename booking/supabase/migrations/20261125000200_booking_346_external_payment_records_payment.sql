-- booking_346: ulkoisen maksun merkintä kirjaa maksun (K4). KirjanpitoTapion marraskuun tarkastus K4 (Joonas 24.11.2026).
-- Ennen: svc_mark_order_paid_external merkitsi tilauksen maksetuksi ilman payments-riviä → myynti ja maksu puuttuivat kirjanpidosta (esim. 15088/15089, 0 €).
-- Nyt: summa, maksupäivä ja maksutapa pakollisia; luodaan payments-rivi (provider manual, paid_at = maksupäivä) → maksurivit ja kuitti
-- syntyvät olemassa olevalla mekanismilla (payments_paid_trg → _issue_receipt). Laskutettu tilaus → maksu kirjataan laskulle (order_invoiced).
-- 0 € tilausta ei merkitä maksetuksi (nothing_to_pay). Asiakkaalle ei lähetetä viestiä (kuittisähköposti merkitään skipped).
-- Vanha 3-parametrinen kutsu palauttaa virheen external_payment_details_required (ohje uuteen kutsuun).
-- Ei datamuutoksia (15088/15089 ennallaan). Rollback: rollbacks/20261125000200_booking_346_ROLLBACK.sql.

create or replace function booking.svc_mark_order_paid_external(p_order_no bigint, p_note text, p_actor text default 'asiakaspalvelu-bot'::text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
begin
  perform booking._err('external_payment_details_required',
    'Ulkoisen maksun merkintä vaatii summan, maksupäivän ja maksutavan: booking.svc_mark_order_paid_external(p_order_no, p_note, p_amount, p_paid_on, p_method[, p_actor]). Maksutavat: bank_transfer, card_terminal, mobilepay, other.');
  return null;
end $function$;

create or replace function booking.svc_mark_order_paid_external(p_order_no bigint, p_note text, p_amount numeric, p_paid_on date, p_method text, p_actor text default 'asiakaspalvelu-bot'::text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  o booking.orders; v_actor text; v_note text; v_line text; v_id bigint; v_unpaid numeric; v_paid_at timestamptz; v_today date; rc record; v_skipped int;
begin
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'asiakaspalvelu-bot');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_today := (now() at time zone booking._tz())::date;
  if p_order_no is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Anna maksettu summa euroina (yli 0 €, enintään 2 desimaalia)'); end if;
  if p_paid_on is null then perform booking._err('paid_on_required', 'Anna maksupäivä (p_paid_on)'); end if;
  if p_paid_on > v_today or p_paid_on < v_today - 400 then perform booking._err('invalid_paid_on', 'Maksupäivä ei voi olla tulevaisuudessa eikä yli 400 päivää sitten'); end if;
  if p_method is null or p_method not in ('bank_transfer', 'card_terminal', 'mobilepay', 'other') then
    perform booking._err('invalid_payment_method', 'Maksutapa: bank_transfer, card_terminal, mobilepay tai other (lasku → laskutus, kumppanikoodi → lunastus)');
  end if;
  if not exists (select 1 from booking.payment_methods m where m.code = p_method and m.active and m.is_manual) then
    perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä');
  end if;

  select * into o from booking.orders where order_no = p_order_no for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.status in ('cancelled', 'expired') then perform booking._err('order_cancelled', 'Peruttua tilausta ei merkitä maksetuksi'); end if;
  if o.payment_status in ('paid', 'refunded', 'partially_refunded') then perform booking._err('already_paid', 'Tilaus on jo maksettu tai hyvitetty'); end if;
  if o.status not in ('confirmed', 'completed') then perform booking._err('not_changeable', 'Vain vahvistetun tilauksen voi merkitä maksetuksi'); end if;
  if o.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian tilausta ei merkitä maksetuksi'); end if;
  if o.payment_status = 'invoiced' or booking._order_invoice_locked(o.id) then
    perform booking._err('order_invoiced', 'Laskutettua tilausta ei merkitä maksetuksi; maksu kirjataan laskulle');
  end if;
  if coalesce(o.total_gross, 0) <= 0 then
    perform booking._err('nothing_to_pay', '0 € tilausta ei merkitä maksetuksi: lisää tilaukselle rivit ja hinnat ensin');
  end if;
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  if p_amount > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;

  -- maksupäivä klo 12 Suomen aikaa, kuitenkin enintään nyt
  v_paid_at := least(now(), (p_paid_on + time '12:00') at time zone booking._tz());
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu ulkoisella maksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, rounding, note, created_by)
  values (o.id, p_method, 'manual', 'pending', p_amount, 0, left('Ulkoinen maksu (' || v_actor || '): ' || v_note, 500), auth.uid()) returning id into v_id;
  perform booking._alloc_payment_lines(v_id);
  update booking.payments set status = 'paid', paid_at = v_paid_at where id = v_id;   -- payments_paid_trg → maksurivit + kuitti
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  -- ei asiakasviestiä: mahdollinen kuittisähköposti jätetään lähettämättä
  update booking.email_outbox set status = 'skipped', last_error = 'svc_mark_order_paid_external: ei asiakasviestiä'
   where payment_id = v_id and status = 'pending';
  get diagnostics v_skipped = row_count;

  v_line := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor || ': ' || v_note
            || ' [ulkoinen maksu ' || to_char(p_amount, 'FM999999990.00') || ' €, ' || p_method || ', ' || to_char(p_paid_on, 'YYYY-MM-DD') || ', maksu #' || v_id || ']';
  update booking.orders set internal_note = concat_ws(E'\n', internal_note, v_line) where id = o.id returning * into o;
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', o.id::text, 'SVC_MARK_ORDER_PAID_EXTERNAL',
          jsonb_build_object('order_no', o.order_no, 'unpaid', v_unpaid),
          jsonb_build_object('order_no', o.order_no, 'payment_status', o.payment_status, 'payment_id', v_id, 'amount', p_amount, 'method', p_method,
                             'paid_on', p_paid_on, 'receipt_no', rc.receipt_no, 'note', v_note, 'actor', v_actor, 'emails_skipped', v_skipped));

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'payment_status', o.payment_status, 'payment_id', v_id,
                            'receipt_id', rc.id, 'receipt_no', rc.receipt_no, 'balance', booking._order_balance(o.id));
end $function$;

revoke all on function booking.svc_mark_order_paid_external(bigint, text, text) from public, anon, authenticated;
revoke all on function booking.svc_mark_order_paid_external(bigint, text, numeric, date, text, text) from public, anon, authenticated;
grant execute on function booking.svc_mark_order_paid_external(bigint, text, text) to service_role;
grant execute on function booking.svc_mark_order_paid_external(bigint, text, numeric, date, text, text) to service_role;
