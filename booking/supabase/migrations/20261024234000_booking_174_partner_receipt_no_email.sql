-- booking_174: kumppanilahjakortin maksu (partner_voucher, partner_voucher_kokemuskauppa, partner_voucher_offerilla, partner_voucher_elamyslahjat)
-- 1) K-kuitti syntyy kirjanpitoa varten, mutta kuittia EI lähetetä sähköpostilla. Omistajan päätös (Joonas, 25.10.2026): "kuitti vain kirjanpitoon ilman sähköpostia".
-- 2) Lahjakortin arvo käsin ennen hyväksyntää (Joonas 25.10.2026): henkilökunta syöttää kumppanilahjakortin arvon (admin_mark_voucher_claim_redeemed p_amount).
--    Arvo > 0 (muuten BK001 / invalid_amount) ja enintään maksettava summa (muuten BK001 / voucher_exceeds_total). Jos arvo < maksettava:
--    kumppanimaksu kirjataan vain arvon suuruisena ja erotus lähetetään asiakkaalle maksulinkkinä (olemassa oleva Visma Pay -maksulinkki
--    booking._create_link_payment + sähköpostilaji payment_link, payload variant = voucher_difference: total, voucher_value, difference).
--    Täysi arvo (tai arvo tyhjä = koko maksettava, kuten ennen) → ei maksulinkkiä. Erotuksen maksu (visma_pay) noudattaa tavallista kuittipolkua (kuitti + kuittisähköposti).
--    email_outbox_claim liittää payment_link-riville lohkon voucher_difference (send-emails näyttää summat; ilman uutta send-emails-versiota viesti on tavallinen maksulinkkiviesti).
--    Botin svc_mark_voucher_claim_redeemed ennallaan.
-- Versio on väliaikainen (tuotannon versio kirjataan ajossa). Ei public-skeemaa. Hinnat, ALV, slugit ennallaan.
-- Procountor ennallaan (mode / daily_enabled / environment): accounting_outbox-rivi syntyy kuten ennen (_issue_receipt ennallaan),
--   kun voucher_claims.partner_voucher_accounted = true. Kun se on false, _acct_excluded estää kuitin kuten ennen (ei muutosta).
--
-- Polku: _vc_pay → payments (status paid) → payments_paid_trg → _on_payment_paid → _issue_receipt (+ _enqueue_email('receipt')).
-- _on_payment_paid: kuitti luodaan kuten ennen; jos maksutapa on kumppanilahjakortti (booking._is_partner_method, booking_173),
--   _enqueue_email('receipt', …) jätetään kutsumatta. Muut maksutavat ennallaan. _issue_receipt, payments_paid_trg, _vc_pay ennallaan.
-- Henkilökunnan "Lähetä kuitti uudelleen" (admin_resend_receipt) toimii edelleen käsin pyydettäessä (ei muutosta).
--
-- Vartija: md5(pg_get_functiondef) luettu tuotannosta sxbofnuisemspgquoxyv 25.10.2026. Ajo keskeytyy eikä mitään muuteta, jos ei vastaa.
--   booking._on_payment_paid(bigint): 86338dfa031158ffc12b0e7025f0a68f -> de9084871640d213d10527a045157bf2   (korvataan)
--   booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text): e14d131d428518ec88581fd3e473af90 -> 525d1fa96fd7c37df4d7e502edf1bf71   (korvataan)
--   booking.email_outbox_claim(integer): 4620f0d7531b524a6a5cfa322fc0e7a7 -> 2db9a1233a06e6293d0877f17de1ab72   (korvataan)
--   riippuvuudet (ei muuteta): _is_partner_method(text) 4796edc6ebadaf599fd78287a75d29e8, _vc_mark_redeemed b394cc612bcce278b66f57122aff4ff9,
--     _create_link_payment(bigint,integer,text) 533ac9af831c0c11e1f504e377a17827, _vc_pay 3c24fd721b0e8bc6f1bdfb8a800c5a0e
-- Uusi: booking._vc_due(booking.orders, booking.voucher_claims) (sama maksettavan laskenta kuin _vc_pay). Uudelleenajettava.
-- Rollback: rollbacks/20261024234000_booking_174_ROLLBACK.sql. Testi: tests/giftcards/t174_partner_receipt_no_email.sql (BEGIN … ROLLBACK).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure));
  if v not in ('86338dfa031158ffc12b0e7025f0a68f', 'de9084871640d213d10527a045157bf2') then ok := false; msg := msg || ' _on_payment_paid=' || v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)')));
  if v is null or v not in ('e14d131d428518ec88581fd3e473af90', '525d1fa96fd7c37df4d7e502edf1bf71') then ok := false; msg := msg || ' admin_mark_voucher_claim_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure));
  if v not in ('4620f0d7531b524a6a5cfa322fc0e7a7', '2db9a1233a06e6293d0877f17de1ab72') then ok := false; msg := msg || ' email_outbox_claim=' || v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._is_partner_method(text)')));
  if v is distinct from '4796edc6ebadaf599fd78287a75d29e8' then ok := false; msg := msg || ' _is_partner_method=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_mark_redeemed(bigint,numeric,text,text,text)')));
  if v is distinct from 'b394cc612bcce278b66f57122aff4ff9' then ok := false; msg := msg || ' _vc_mark_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v is distinct from '533ac9af831c0c11e1f504e377a17827' then ok := false; msg := msg || ' _create_link_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_pay(booking.orders,booking.voucher_claims,numeric)')));
  if v is distinct from '3c24fd721b0e8bc6f1bdfb8a800c5a0e' then ok := false; msg := msg || ' _vc_pay=' || coalesce(v, 'puuttuu'); end if;
  if not ok then raise exception 'booking_174: funktioiden md5 ei vastaa tuotantoa eikä booking_174:ää (%); mitään ei muutettu', msg; end if;
end $g$;

-- 1) Kuittisähköposti pois kumppanilahjakortin maksulta
CREATE OR REPLACE FUNCTION booking._on_payment_paid(p_payment_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_order bigint; v_method text;
begin
  v_id := booking._issue_receipt(p_payment_id);
  if v_id is not null then
    select order_id, method into v_order, v_method from booking.payments where id = p_payment_id;
    -- booking_174: kumppanilahjakortti → kuitti vain kirjanpitoon, ei kuittisähköpostia
    if booking._is_partner_method(v_method) then return; end if;
    perform booking._enqueue_email('receipt', v_order, v_id, p_payment_id, 'receipt:' || v_id);
  end if;
end $function$;

-- 2a) Maksettava summa lunastuspyynnölle (sama kuin _vc_pay: pending-tilaus = summa - nettomaksut, muuten maksamaton; rivikohtainen pyyntö = rivin jäännös)
CREATE OR REPLACE FUNCTION booking._vc_due(o booking.orders, c booking.voucher_claims)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_unpaid numeric; v_rem numeric;
begin
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if c.order_item_id is not null then
    select u.remaining into v_rem from booking._order_uncovered(o.id, false) u where u.item_id = c.order_item_id;
    v_unpaid := least(v_unpaid, coalesce(v_rem, 0));
  end if;
  return greatest(coalesce(v_unpaid, 0), 0);
end $function$;
revoke all on function booking._vc_due(booking.orders, booking.voucher_claims) from public, anon, authenticated;

-- 2b) Henkilökunnan lunastus: arvo käsin, erotus maksulinkkinä
CREATE OR REPLACE FUNCTION booking.admin_mark_voucher_claim_redeemed(p_id bigint, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; o booking.orders; v jsonb; v_due numeric; v_link jsonb; v_pid bigint; v_diff numeric; v_mail boolean := false;
begin
  perform booking._require_permission('giftcards.manage');
  if p_amount is not null then
    if p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 € (enintään 2 desimaalia)'); end if;
    select * into c from booking.voucher_claims where id = p_id for update;
    if found and c.status in ('open', 'processing', 'problem') then
      select * into o from booking.orders where id = c.order_id for update;
      if found and o.status in ('pending', 'confirmed') and o.external_source is null then
        v_due := booking._vc_due(o, c);
        if p_amount > v_due then
          perform booking._err('voucher_exceeds_total', format('Lahjakortin arvo %s € ylittää maksettavan summan %s €', p_amount, v_due));
        end if;
      end if;
    end if;
  end if;
  v := booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, 'staff');
  -- booking_174: arvo pienempi kuin maksettava → erotus maksulinkkinä asiakkaalle (Visma Pay -linkki, sähköposti payment_link / voucher_difference)
  if v_due is not null and p_amount < v_due and not coalesce((v ->> 'already')::boolean, false) and (v ->> 'payment_id') is not null then
    select * into o from booking.orders where id = o.id;
    v_link := booking._create_link_payment(o.id, 14, 'Kumppanilahjakortin erotus, pyyntö #' || p_id);
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    v_mail := booking._enqueue_email('payment_link', o.id, null, v_pid, 'payment_link:voucher_difference:' || p_id || ':' || v_pid,
                jsonb_build_object('variant', 'voucher_difference', 'claim_id', p_id, 'voucher_value', (v ->> 'amount')::numeric, 'difference', v_diff,
                                   'total', (v ->> 'amount')::numeric + v_diff));
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.voucher_claims', p_id::text, 'VOUCHER_DIFFERENCE_LINK', null,
            jsonb_build_object('voucher_value', (v ->> 'amount')::numeric, 'due', v_due, 'difference', v_diff, 'link_payment_id', v_pid, 'email_queued', v_mail));
  end if;
  return v || jsonb_build_object('voucher_value', case when (v ->> 'already')::boolean then null else (v ->> 'amount')::numeric end, 'due', v_due,
    'difference', v_diff, 'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._vismapay_online()) end,
    'email_queued', v_mail);
end $function$;

-- 2c) Sähköpostijono: payment_link + voucher_difference → summat viestiin (muut lajit ennallaan)
CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    when z.item->>'kind' = 'payment_link'
    then z.item || coalesce((select jsonb_build_object('voucher_difference', jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference'))
                               from booking.email_outbox e where e.id = (z.item->>'id')::bigint and e.payload ->> 'variant' = 'voucher_difference'), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$function$;
