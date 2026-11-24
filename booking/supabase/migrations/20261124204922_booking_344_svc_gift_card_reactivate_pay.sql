-- booking_344: svc-funktiot lahjakortin palautukseen voimaan ja tilauksen maksamiseen lahjakortilla (Asiakaspalvelu, service_role).
-- Ei sähköpostia, kuittia, maksulinkkiä eikä outbox-rivejä. Joonas 24.11.2026 klo 22.45 (KirjanpitoTapion chat), tilaus 15290 / kortti 605.

create or replace function booking.svc_reactivate_gift_card(p_gift_card_id bigint, p_note text, p_actor text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare g booking.gift_cards; v_note text; v_actor text; v_status text;
begin
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_actor := nullif(btrim(coalesce(p_actor, '')), '');
  if v_note is null or char_length(v_note) < 3 or char_length(v_note) > 500 then perform booking._err('note_required', 'Anna syy (p_note, 3–500 merkkiä)'); end if;
  if v_actor is null or char_length(v_actor) > 100 then perform booking._err('actor_required', 'Anna tekijä (p_actor)'); end if;
  if p_gift_card_id is null then perform booking._err('not_found', 'Korttia ei löydy'); end if;
  select * into g from booking.gift_cards where id = p_gift_card_id for update;
  if not found then perform booking._err('not_found', 'Korttia ei löydy'); end if;
  if not ((g.source = 'native' and g.issuer = 'own') or (g.source = 'johku' and g.issuer = 'johku')) then
    perform booking._err('partner_card', 'Vain oman tai Johku-lahjakortin voi palauttaa voimaan');
  end if;
  if g.status <> 'cancelled' then perform booking._err('invalid_status', 'Vain mitätöidyn kortin voi palauttaa voimaan (tila nyt: ' || g.status || ')'); end if;
  if g.balance <= 0 then perform booking._err('gift_card_empty', 'Kortin saldo on 0 €'); end if;
  if g.valid_to is not null and g.valid_to < booking._gc_today() then perform booking._err('gift_card_expired', 'Kortin voimassaolo on päättynyt'); end if;
  if g.source = 'native' and not exists (select 1 from booking.gift_card_ledger l where l.gift_card_id = g.id and l.reason in ('purchase', 'manual_issue')) then
    perform booking._err('gift_card_not_paid', 'Kortti ei ole koskaan aktivoitunut (ostoa ei ole maksettu)');
  end if;
  v_status := 'active';
  update booking.gift_cards set status = v_status where id = g.id;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, created_by, note, meta)
  values (g.id, 0, g.balance, 'reactivate', auth.uid(), v_note, jsonb_build_object('actor', v_actor, 'via', 'svc_reactivate_gift_card'));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'gift_cards', g.id::text, 'SVC_REACTIVATE_GIFT_CARD',
          jsonb_build_object('status', g.status, 'balance', g.balance, 'valid_to', g.valid_to),
          jsonb_build_object('status', v_status, 'balance', g.balance, 'note', v_note, 'actor', v_actor));
  return jsonb_build_object('ok', true, 'id', g.id, 'code_last4', right(g.code, 4), 'old_status', g.status, 'status', v_status,
                            'balance', g.balance, 'valid_to', g.valid_to);
end
$function$;

create or replace function booking.svc_pay_order_with_gift_card(p_order_id bigint, p_gift_card_id bigint, p_amount numeric, p_note text, p_actor text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare o booking.orders; g booking.gift_cards; v_note text; v_actor text; v_unpaid numeric; v_open_ref numeric; v_max numeric;
        v_id bigint; v_card booking.gift_cards; v_old_ps text; v_bal jsonb; v_cancelled int;
begin
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_actor := nullif(btrim(coalesce(p_actor, '')), '');
  if v_note is null or char_length(v_note) < 3 or char_length(v_note) > 500 then perform booking._err('note_required', 'Anna syy (p_note, 3–500 merkkiä)'); end if;
  if v_actor is null or char_length(v_actor) > 100 then perform booking._err('actor_required', 'Anna tekijä (p_actor)'); end if;
  if p_order_id is null or p_gift_card_id is null then perform booking._err('invalid_param', 'Tilaus tai kortti puuttuu'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;

  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: maksuja ei voi muuttaa'); end if;
  if o.external_source is not null or o.johku_order_no is not null or o.source_channel = 'johku_import'
     or o.status not in ('pending', 'confirmed', 'completed') then
    perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
  end if;
  if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;

  select * into g from booking.gift_cards where id = p_gift_card_id for update;
  if not found then perform booking._err('gift_card_not_found', 'Korttia ei löydy'); end if;
  if not ((g.source = 'native' and g.issuer = 'own') or (g.source = 'johku' and g.issuer = 'johku')) then
    perform booking._err('partner_card', 'Vain oma tai Johku-lahjakortti');
  end if;
  -- Ei kuittia eikä sähköpostia: payments_paid_trg ohittaa kuitin vain kirjanpidon ulkopuolisille korteille (_acct_excluded: Johku-alkuperä tai kaupanpäällinen).
  -- Oman myydyn kortin lunastus loisi tiedoksi-kuitin ja sähköpostin, joten se tehdään hallinnan/kassan polulla.
  if not (g.accounting_origin = 'johku' or g.complimentary) then
    perform booking._err('receipt_path_required', 'Oman myydyn kortin lunastus luo kuitin: käytä hallinnan lahjakorttimaksua');
  end if;
  if g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then
    perform booking._err('johku_cards_closed', 'Johku-korttien lunastus ei ole käytössä');
  end if;
  if g.status <> 'active' then perform booking._err('gift_card_inactive', 'Kortti ei ole voimassa (tila: ' || g.status || ')'); end if;
  if g.valid_to is not null and g.valid_to < booking._gc_today() then perform booking._err('gift_card_expired', 'Kortin voimassaolo on päättynyt'); end if;
  if not g.balance_verified then perform booking._err('gift_card_inactive', 'Kortin saldoa ei ole vahvistettu'); end if;
  if p_amount > g.balance + 0.004 then perform booking._err('insufficient_balance', format('Kortin saldo on %s €', g.balance)); end if;

  -- Maksettava = maksamaton osuus + tilauksen keskeneräiset hyvitykset (requested/processing), jotka palauttavat rahaa asiakkaalle.
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  select coalesce(sum(f.amount), 0) into v_open_ref
    from booking.refunds f join booking.payments p on p.id = f.payment_id
   where p.order_id = o.id and f.status in ('requested', 'processing');
  v_max := v_unpaid + v_open_ref;
  if v_max <= 0.004 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
  if p_amount > v_max + 0.004 then
    perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksettavan (%s € maksamatta + %s € hyvityksiä kesken)', v_unpaid, v_open_ref));
  end if;

  v_old_ps := o.payment_status;
  -- Kuten kassan/hallinnan lahjakorttipolku (_gc_redeem): avoimet maksupyynnöt korvataan, ei uutta linkkiä.
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu lahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  get diagnostics v_cancelled = row_count;
  insert into booking.payments(order_id, method, provider, status, amount, gift_card_id, note, created_by)
  values (o.id, 'gift_card', 'manual', 'pending', p_amount, g.id, left(concat_ws(' | ', 'Lahjakortti …' || right(g.code, 4), v_note), 1000), auth.uid())
  returning id into v_id;
  perform booking._alloc_payment_lines(v_id);
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;   -- payments_paid_trg: _acct_excluded → ei kuittia eikä sähköpostia
  if exists (select 1 from booking.receipts r where r.payment_id = v_id) then
    perform booking._err('receipt_created', 'Kuitti syntyi odottamatta: muutos peruttu');
  end if;
  perform booking._gc_apply(g.id, -p_amount, 'redemption', o.id, v_id, v_note, jsonb_build_object('actor', v_actor, 'via', 'svc_pay_order_with_gift_card'));
  select * into v_card from booking.gift_cards where id = g.id;
  if v_card.single_order and v_card.balance > 0 then
    perform booking._gc_apply(g.id, -v_card.balance, 'single_order_forfeit', o.id, v_id, 'Kertakäyttökortti: jäännös ei käytettävissä');
    select * into v_card from booking.gift_cards where id = g.id;
  end if;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  select * into o from booking.orders where id = o.id;
  v_bal := booking._order_balance(o.id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'orders', o.id::text, 'SVC_PAY_ORDER_WITH_GIFT_CARD',
          jsonb_build_object('payment_status', v_old_ps, 'card_balance', g.balance, 'card_status', g.status),
          jsonb_build_object('payment_id', v_id, 'gift_card_id', g.id, 'amount', p_amount, 'payment_status', o.payment_status,
                             'card_balance', v_card.balance, 'card_status', v_card.status, 'open_refunds', v_open_ref,
                             'cancelled_pending_payments', v_cancelled, 'note', v_note, 'actor', v_actor));
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'order_id', o.id, 'order_no', o.order_no, 'amount', p_amount,
    'payment_status', o.payment_status, 'balance', v_bal, 'open_refunds', v_open_ref,
    'gift_card', jsonb_build_object('id', v_card.id, 'code_last4', right(v_card.code, 4), 'balance', v_card.balance, 'status', v_card.status));
end
$function$;

revoke all on function booking.svc_reactivate_gift_card(bigint, text, text) from public, anon, authenticated;
revoke all on function booking.svc_pay_order_with_gift_card(bigint, bigint, numeric, text, text) from public, anon, authenticated;
grant execute on function booking.svc_reactivate_gift_card(bigint, text, text) to service_role;
grant execute on function booking.svc_pay_order_with_gift_card(bigint, bigint, numeric, text, text) to service_role;
