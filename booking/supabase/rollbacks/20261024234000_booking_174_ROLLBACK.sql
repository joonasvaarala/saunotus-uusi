-- booking_174 ROLLBACK: palauttaa tuotannon määrittelyt (luettu sxbofnuisemspgquoxyv 25.10.2026) ja poistaa booking._vc_due. Aja yhdessä transaktiossa.
--   booking._on_payment_paid(bigint): de9084871640d213d10527a045157bf2 -> 86338dfa031158ffc12b0e7025f0a68f  (kuittisähköposti taas kaikille maksutavoille)
--   booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text): 525d1fa96fd7c37df4d7e502edf1bf71 -> e14d131d428518ec88581fd3e473af90  (ei arvon tarkistusta, ei erotuslinkkiä)
--   booking.email_outbox_claim(integer): 2db9a1233a06e6293d0877f17de1ab72 -> 4620f0d7531b524a6a5cfa322fc0e7a7
-- Jo luotuja kuitteja, maksuja, maksulinkkejä ja jonossa olevia sähköposteja ei muuteta (jonossa oleva erotusviesti lähtee tavallisena maksulinkkiviestinä).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure));
  if v not in ('de9084871640d213d10527a045157bf2', '86338dfa031158ffc12b0e7025f0a68f') then ok := false; msg := msg || ' _on_payment_paid=' || v; end if;
  v := md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure));
  if v not in ('525d1fa96fd7c37df4d7e502edf1bf71', 'e14d131d428518ec88581fd3e473af90') then ok := false; msg := msg || ' admin_mark_voucher_claim_redeemed=' || v; end if;
  v := md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure));
  if v not in ('2db9a1233a06e6293d0877f17de1ab72', '4620f0d7531b524a6a5cfa322fc0e7a7') then ok := false; msg := msg || ' email_outbox_claim=' || v; end if;
  if not ok then raise exception 'booking_174 rollback: md5 ei vastaa booking_174:ää eikä tuotannon alkuperäistä (%); mitään ei muutettu', msg; end if;
end $g$;

CREATE OR REPLACE FUNCTION booking._on_payment_paid(p_payment_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_order bigint;
begin
  v_id := booking._issue_receipt(p_payment_id);
  if v_id is not null then
    select order_id into v_order from booking.payments where id = p_payment_id;
    perform booking._enqueue_email('receipt', v_order, v_id, p_payment_id, 'receipt:' || v_id);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_mark_voucher_claim_redeemed(p_id bigint, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('giftcards.manage');
  return booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, 'staff');
end $function$;

CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$function$;

drop function if exists booking._vc_due(booking.orders, booking.voucher_claims);

do $c$
begin
  if md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure)) <> '86338dfa031158ffc12b0e7025f0a68f'
     or md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) <> 'e14d131d428518ec88581fd3e473af90'
     or md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure)) <> '4620f0d7531b524a6a5cfa322fc0e7a7' then
    raise exception 'booking_174 rollback: palautetut määrittelyt eivät vastaa tuotannon md5:tä; peruttu';
  end if;
end $c$;
