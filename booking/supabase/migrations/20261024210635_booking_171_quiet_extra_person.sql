-- booking_171: hiljaisen ajan ale (booking_162) vain vuoron perushinnasta; lisähenkilö aina täyshintainen.
-- Väliaikainen versio 20261024210635 (tuotannon versio voi olla eri; Bottiavustus ajaa). Ei public-skeemaa. Hinnat, ALV, slugit ennallaan.
--
-- Virhe (Joonas 25.10.): kb 26 jälkilöylyt ma 26.10. 19–21, −20 %: 180 € → 144 € (sis. 6 hlö), mutta lisähenkilö näkyi +8 € ja palvelin
--   alensi myös lisähenkilöt: _quiet_apply laski alen koko varausrivistä (line_total_gross = perushinta + lisähenkilöt) ja
--   public_preview_code samoin (pr.total). 7 hlö: 190 − 38 = 152 €. Oikein: 190 − 36 = 154 € (ale 20 % vain 180 €:sta, lisähenkilö 10 €).
--   public_quiet_offers (_quiet_offers) laski jo oikein perushinnasta (discounted_price 144, extra_person_price 10) → ei muutosta.
-- Korjaus: uusi booking._quiet_base(price_breakdown, rivin summa): price_mode fixed_plus_extra → perushinta (breakdown.base, enintään rivin summa),
--   fixed / per_person → koko rivi kuten ennen. _quiet_apply ja public_preview_code laskevat alen siitä. price_breakdown.quiet saa lisäksi
--   kentän discount_base (base = rivin summa ennen alea kuten ennen). public_create_booking_code lukee alen price_breakdown.quiet.amount-kentästä
--   (ei muutosta). Jo tehdyt varaukset ennallaan.
--
-- Vartija: korvattavien funktioiden md5(pg_get_functiondef) on oltava tuotannon (luettu sxbofnuisemspgquoxyv 25.10.2026) tai jo tämän migraation,
-- muuten ajo keskeytyy eikä mitään muuteta. Uudelleenajettava. Rollback palauttaa tuotannon määrittelyt täsmälleen:
--   booking._quiet_apply(bigint,jsonb): 92d6a01979c46e9f12b5edb2f9dacd2a -> dd2139dc889d981e6623ef1fceaeec3d
--   booking.public_preview_code(text,bigint,date,integer,jsonb,text,text): 4816fbaf5149e501a128aed40f2bf505 -> e8fe514b4ec9db4043d388e5547f94ad
-- Uusi: booking._quiet_base(jsonb,numeric) (ei anon/authenticated-oikeuksia).
-- Rollback: rollbacks/20261024210635_booking_171_ROLLBACK.sql. Testi: tests/discounts/t171_quiet_extra_person.sql (paikallinen PG17).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._quiet_apply(bigint,jsonb)'::regprocedure));
  if v not in ('92d6a01979c46e9f12b5edb2f9dacd2a', 'dd2139dc889d981e6623ef1fceaeec3d') then ok := false; msg := msg || ' _quiet_apply=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure));
  if v not in ('4816fbaf5149e501a128aed40f2bf505', 'e8fe514b4ec9db4043d388e5547f94ad') then ok := false; msg := msg || ' public_preview_code=' || v; end if;
  if not ok then raise exception 'booking_171: funktioiden md5 ei ole tuotannon eikä booking_171:n (%); mitään ei muutettu', msg; end if;
end $g$;

create or replace function booking._quiet_base(p_breakdown jsonb, p_total numeric)
returns numeric language sql immutable set search_path = '' as $f$
  select case
    when p_total is null or p_total <= 0 then coalesce(p_total, 0)
    when p_breakdown ->> 'mode' = 'fixed_plus_extra' and coalesce(p_breakdown ->> 'base', '') ~ '^\d+(\.\d+)?$'
      then least(p_total, (p_breakdown ->> 'base')::numeric)
    else p_total
  end
$f$;
comment on function booking._quiet_base(jsonb, numeric) is 'booking_171: hiljaisen ajan alen pohja: fixed_plus_extra → perushinta (lisähenkilöt täyshintaisia), muuten koko rivi.';
revoke all on function booking._quiet_base(jsonb, numeric) from public, anon, authenticated;

-- booking._quiet_apply(bigint,jsonb) (booking_171, md5 dd2139dc889d981e6623ef1fceaeec3d)
CREATE OR REPLACE FUNCTION booking._quiet_apply(p_order_id bigint, p_quiet jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_item booking.order_items; v_amt numeric; v_base numeric;
begin
  if p_quiet is null or p_order_id is null then return 0; end if;
  select * into v_item from booking.order_items where order_id = p_order_id and kind = 'reservation' order by id limit 1 for update;
  if v_item.id is null or coalesce(v_item.line_total_gross, 0) <= 0 then return 0; end if;
  -- booking_171: ale vain vuoron perushinnasta; lisähenkilöt (fixed_plus_extra) aina täyshintaisia
  v_base := booking._quiet_base(v_item.price_breakdown, v_item.line_total_gross);
  v_amt := least(v_base, round(v_base * (p_quiet ->> 'percent')::numeric / 100, 2));
  if v_amt <= 0 then return 0; end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = v_amt,
         price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('quiet', jsonb_build_object(
           'rule_id', (p_quiet ->> 'rule_id')::bigint, 'percent', (p_quiet ->> 'percent')::numeric, 'base', v_item.line_total_gross, 'discount_base', v_base,
           'amount', v_amt, 'hours_left', (p_quiet ->> 'hours_left')::numeric, 'source', 'quiet'))
   where id = v_item.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  return v_amt;
end $function$
;

-- booking.public_preview_code(text,bigint,date,integer,jsonb,text,text) (booking_171, md5 e8fe514b4ec9db4043d388e5547f94ad)
CREATE OR REPLACE FUNCTION booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer, p_addons jsonb DEFAULT NULL::jsonb, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162
begin
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if r.id is null or p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', pr.total));
  v_sub := pr.total;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      -- booking_166: saunarituaali-elementti mukaan esikatseluun samana rivinä kuin varauksessa (tuote + palvelimen hinta)
      if jsonb_typeof(e) = 'object' and e ? 'ritual_start' and coalesce(e ->> 'quantity', '') ~ '^\d{1,3}$' and (e ->> 'quantity')::int > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', -1, 'product_id', (booking._ritual_addon_cfg() ->> 'product_id')::bigint, 'kind', 'reservation',
                     'gross', round(booking._treatment_price((booking._ritual_addon_cfg() ->> 'product_id')::bigint, least((e ->> 'quantity')::int, p_persons)), 2)));
        v_sub := v_sub + round(booking._treatment_price((booking._ritual_addon_cfg() ->> 'product_id')::bigint, least((e ->> 'quantity')::int, p_persons)), 2);
        continue;
      end if;
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;

  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti + yhteystiedot, jotka eivät ole omistajan → sama vastaus kuin tuntemattomalla koodilla
  if v_card.id is not null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
     and not booking._annual_card_owner_ok(v_card, p_email, p_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  if v_card.id is not null or d.is_annual_card_code then
    v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
    if v_err is null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and booking._annual_limit(v_card.customer_id, p_email, p_phone) then v_err := 'annual_card_limit'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    select * into pr from booking._rule_price(p_rule_id, booking._annual_max_persons());
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'persons', booking._annual_max_persons(), 'addons_allowed', false, 'subtotal', pr.total, 'discount', pr.total, 'total', 0,
      'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  -- booking_162: hiljaisen ajan ale ei pinoudu koodin kanssa; koodi voittaa vain jos se on suurempi etu
  v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
  -- booking_171: ale vain vuoron perushinnasta (lisähenkilöt täyshintaisia), sama kuin _quiet_apply
  if v_quiet is not null then
    v_qamt := least(booking._quiet_base(pr.breakdown, pr.total), round(booking._quiet_base(pr.breakdown, pr.total) * (v_quiet ->> 'percent')::numeric / 100, 2));
  end if;
  if v_qamt > 0 and v_qamt >= (v_calc ->> 'discount')::numeric then
    return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
      'discount', v_qamt, 'total', v_sub - v_qamt, 'addons_allowed', true, 'discount_source', 'quiet', 'code_applied', false,
      'code_discount', (v_calc ->> 'discount')::numeric, 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true)
    || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'code_applied', true,
         'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end;
end $function$
;

revoke all on function booking._quiet_apply(bigint, jsonb) from public, anon, authenticated;
