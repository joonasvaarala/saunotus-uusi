-- =============================================================================
-- booking_143_annual_code_hardening.sql (paketti 10 jatko: vuosikortti- ja alennuskoodien kovennus)
-- =============================================================================
-- Kirjoittaa vain booking-skeemaan. Ei muuta hintoja, ALV-kantoja eikä tauluja (ei uusia sarakkeita).
--  1) Vuosikorttikoodit: _generate_annual_card_code luo 10 merkin satunnaiskoodin aakkostosta
--     ABCDEFGHJKMNPQRSTUVWXYZ23456789 (ei sekoittuvia 0/O, 1/I/L). Satunnaisuus gen_random_uuid():sta
--     (pg_strong_random, kryptografinen; ei pgcrypto-riippuvuutta), tasajakauma hylkäysotannalla. Yksilöllisyys:
--     advisory lock + tarkistus annual_cards / discount_codes + yksilöllinen indeksi annual_cards_code_uq.
--     Olemassa olevia koodeja ei muuteta (tuotannossa 0 korttia 24.10.2026).
--     Rate limit (_code_rate_ok, käyttää _rate_limit-funktiota): IP 20 / 10 min kuten ennen; jos IP:tä ei tiedetä,
--     yhteinen raja 200 / 10 min; lisäksi sähköposti 20 / 10 min, puhelin 20 / 10 min ja henkilökohtainen
--     vuosikorttikoodi 20 / 10 min (koodi tallennetaan rajaukseen md5-tiivisteenä). Yhteisillä alennus- ja
--     vuosikorttikoodeilla ei ole koodikohtaista rajaa (monta asiakasta käyttää samaa koodia).
--     Henkilökohtainen vuosikortti, jonka omistaja ei täsmää annettuun sähköpostiin/puhelimeen, palauttaa saman
--     geneerisen virheen kuin tuntematon koodi (invalid_code). Omistajatarkistus tehdään ennen muita
--     vuosikorttitarkistuksia, ettei esim. "ei voimassa" -virhe paljasta kortin olemassaoloa.
--  2) Vuosikorttivaraus (reservations.annual_card_id, 0 €): tilausrivin discount_amount = vuoron alkuperäinen hinta
--     (_rule_price) raportointia varten. Triggeri reservations_annual_discount: lisäys ja muutos (sääntö /
--     henkilömäärä) – kattaa verkkovarauksen koodilla ja hallinnan vuosikorttivarauksen. Rivin summa pysyy 0 €.
--  3) Alennuskoodin käyttökerta: ennen palautui vain maksamattoman pidon (pending → cancelled/expired) peruutuksessa;
--     vahvistetun tilauksen peruutus (asiakas, hallinta, hyvitys peruutuksella, kassan mitätöinti) ei palauttanut.
--     Koodissa/kommenteissa ei ollut syytä rajaukselle, joten nyt kaikki siirtymät aktiivisesta tilasta tilaan
--     cancelled / expired palauttavat käyttökerran (myös yhteinen vuosikorttikoodi), ja tilauksen palautus
--     (cancelled/expired → muu tila) ottaa sen takaisin. Vuosikortin "yksi tuleva varaus" -raja laskee vain voimassa
--     olevat varaukset (_res_active), joten peruttu vuosikorttivaraus vapauttaa kortin jo nyt (testattu t143:ssa).
-- EI muuteta: maksettu tuotteen 43 tilaus luo vuosikortin myös kassalla/POSissa asetuksesta annual_card_sale_enabled
-- riippumatta (odottaa omistajan päätöstä).
-- Rollback: rollbacks/20261024160000_booking_143_ROLLBACK.sql (palauttaa booking_142:n määritelmät täsmälleen).
-- =============================================================================
set local lock_timeout = '5s';

-- ---------------------------------------------------------------- 1) satunnainen vuosikorttikoodi
create or replace function booking._generate_annual_card_code() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';   -- 31 merkkiä: ei 0/O, 1/I/L
  n constant int := 31; len constant int := 10; c text; b bytea; v int;
begin
  perform pg_advisory_xact_lock(hashtextextended('booking:generate:annual', 0));
  for i in 1..1000 loop
    c := '';
    while char_length(c) < len loop
      b := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');   -- 16 tavua, tavut 6 ja 8 sisältävät versio-/varianttibitit
      for k in 0..15 loop
        continue when k in (6, 8);
        v := get_byte(b, k);
        continue when v >= 248;                                       -- 248 = 8 × 31: tasajakauma
        c := c || substr(alphabet, 1 + v % n, 1);
        exit when char_length(c) = len;
      end loop;
    end loop;
    if not exists (select 1 from booking.annual_cards where code = c) and not exists (select 1 from booking.discount_codes where code = c) then
      return c;
    end if;
  end loop;
  perform booking._err('code_exhausted', 'Vapaata vuosikorttikoodia ei löytynyt');
  return null;
end $$;

-- Koodin esikatselun / koodivarauksen rate limit. true = sallittu. Kirjaa yrityksen (_rate_limit).
create or replace function booking._code_rate_ok(p_code text, p_email text, p_phone text, p_ip text) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare v_email text := nullif(lower(btrim(coalesce(p_email, ''))), ''); v_phone text := booking._phone_key(p_phone);
begin
  if p_ip is not null then
    if not booking._rate_limit('code:ip:' || p_ip, 20, interval '10 minutes') then return false; end if;
  else
    if not booking._rate_limit('code:noip', 200, interval '10 minutes') then return false; end if;
  end if;
  if v_email is not null and not booking._rate_limit('code:email:' || v_email, 20, interval '10 minutes') then return false; end if;
  if v_phone is not null and not booking._rate_limit('code:phone:' || v_phone, 20, interval '10 minutes') then return false; end if;
  if p_code is not null and p_code <> '' and exists (select 1 from booking.annual_cards where code = p_code)
     and not booking._rate_limit('code:card:' || md5(p_code), 20, interval '10 minutes') then return false; end if;
  return true;
end $$;

-- ---------------------------------------------------------------- 1) esikatselu: omistaja ei täsmää → invalid_code
create or replace function booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer,
  p_addons jsonb default null, p_email text default null, p_phone text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
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
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true);
end $$;

-- Esikatselun rate limit erillisenä (stable-funktio ei voi kirjata): kassa kutsuu public_check_code, joka kirjaa yrityksen.
create or replace function booking.public_check_code(p_code text, p_rule_id bigint, p_date date, p_persons integer,
  p_addons jsonb default null, p_email text default null, p_phone text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not booking._code_rate_ok(booking._norm_code(p_code), p_email, p_phone, booking._client_ip()) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  return booking.public_preview_code(p_code, p_rule_id, p_date, p_persons, p_addons, p_email, p_phone);
end $$;

-- ---------------------------------------------------------------- 1) varaus koodilla
create or replace function booking.public_create_booking_code(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text,
  p_marketing_consent boolean default false, p_locale text default 'fi', p_note text default null, p_customer_kind text default 'private',
  p_company jsonb default null, p_addons jsonb default null, p_code text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private')));
  v_card booking.annual_cards; d booking.discount_codes; v_res jsonb; v_order booking.orders; v_cust bigint; v_err text; v_detail text; v_msg text;
  v_lines jsonb; v_calc jsonb; s jsonb; v_disc numeric; v_total numeric; pr record; v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
begin
  if v_code = '' then
    return booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                         p_customer_kind, p_company, p_addons);
  end if;
  if char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  if not booking._code_rate_ok(v_code, v_email, v_phone, v_ip) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti, jonka omistaja ei täsmää → sama vastaus kuin tuntemattomalla koodilla (ennen muita tarkistuksia)
  if v_card.id is not null and not booking._annual_card_owner_ok(v_card, v_email, v_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  -- ---- vuosikortti / yhteinen vuosikorttikoodi
  if v_card.id is not null or d.is_annual_card_code then
    if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
      return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
    end if;
    if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
    if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
    if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
    if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
    if p_date is null or p_date < (now() at time zone booking._tz())::date
       or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
      return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
    end if;
    v_err := case
      when v_kind <> 'private' then 'annual_card_private_only'
      when p_addons is not null and jsonb_typeof(p_addons) = 'array' and exists (select 1 from jsonb_array_elements(p_addons) x where coalesce(x ->> 'quantity', '0') <> '0') then 'annual_card_no_addons'
      when p_persons is distinct from booking._annual_max_persons() then 'annual_card_persons'
      else booking._annual_rule_check(p_rule_id, p_date, v_card, d) end;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    begin
      if v_card.id is not null then v_cust := v_card.customer_id;
      else
        v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                           (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
      end if;
      perform booking._annual_lock_identity(v_cust, v_email, v_phone);
      if booking._annual_limit(v_cust, v_email, v_phone) then perform booking._err('annual_card_limit', booking._code_msg('annual_card_limit')); end if;
      -- henkilökohtaisen kortin rivin alennus (alkuperäinen hinta) kirjataan triggerissä reservations_annual_discount
      v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note, 'confirmed', null, true,
                                            null, null, case when v_card.id is null then 0 end, v_card.id);
      if d.id is not null then
        select * into pr from booking._rule_price(p_rule_id, p_persons);
        update booking.order_items set discount_code_id = d.id, discount_amount = pr.total
         where order_id = (v_res ->> 'order_id')::bigint and kind = 'reservation';
        update booking.orders set discount_code_id = d.id where id = (v_res ->> 'order_id')::bigint;
        update booking.discount_codes set used_count = used_count + 1 where id = d.id;
      end if;
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values ((v_res ->> 'order_id')::bigint, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikorttivaraus verkossa (' || v_code || ')');
      update booking.orders set payment_status = 'paid' where id = (v_res ->> 'order_id')::bigint;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
    end;
    return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', 'confirmed',
                              'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at', 'total', 0, 'addons_total', 0,
                              'hold_expires_at', null, 'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name',
                              'customer_kind', 'private', 'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'discount', (select coalesce(sum(discount_amount), 0) from booking.order_items where order_id = (v_res ->> 'order_id')::bigint))
           || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
  end if;

  -- ---- alennuskoodi
  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  begin
    v_res := booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                           p_customer_kind, p_company, p_addons);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;
    select * into v_order from booking.orders where public_token = (v_res ->> 'token')::uuid for update;
    select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind, 'gross', oi.line_total_gross) order by oi.id), '[]'::jsonb)
      into v_lines from booking.order_items oi where oi.order_id = v_order.id;
    v_calc := booking._discount_split(d, v_lines);
    v_disc := (v_calc ->> 'discount')::numeric;
    if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
    for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
      update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
             line_total_gross = line_total_gross - (s ->> 'amount')::numeric
       where id = (s ->> 'key')::bigint and order_id = v_order.id;
    end loop;
    update booking.orders set discount_code_id = d.id,
           total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = v_order.id), 0)
     where id = v_order.id returning total_gross into v_total;
    update booking.discount_codes set used_count = used_count + 1 where id = d.id;
    if v_total > 0 then
      update booking.payments set amount = v_total where order_id = v_order.id and status = 'pending' and provider = 'manual';
    else   -- 100 % alennus: ei maksettavaa → vahvistetaan heti
      update booking.payments set status = 'cancelled' where order_id = v_order.id and status = 'pending';
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values (v_order.id, 'other', 'manual', 'paid', 0, now(), 'Alennuskoodi ' || d.code || ' (100 %)');
      update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = v_order.id and status = 'pending';
      update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), hold_kind = null where id = v_order.id and status = 'pending';
      update booking.orders set payment_status = 'paid' where id = v_order.id;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  select * into v_order from booking.orders where id = v_order.id;
  return v_res || jsonb_build_object('total', v_total, 'status', v_order.status, 'hold_expires_at',
                    (select min(hold_expires_at) from booking.reservations where order_id = v_order.id and status = 'pending'),
                    'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount',
                    'addons_total', (select coalesce(sum(line_total_gross), 0) from booking.order_items where order_id = v_order.id and kind = 'addon'))
                || booking._checkout_state_json(v_order.id);
end $$;

-- ---------------------------------------------------------------- 2) vuosikorttivarauksen alennus = alkuperäinen hinta
create or replace function booking._annual_res_discount_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_full numeric;
begin
  if new.rule_id is null or new.order_item_id is null then return null; end if;
  begin
    select total into v_full from booking._rule_price(new.rule_id, new.persons);
  exception when others then return null;   -- hinnaton sääntö: ei kaadeta varausta, alennus jää ennalleen
  end;
  update booking.order_items set discount_amount = coalesce(v_full, 0)
   where id = new.order_item_id and kind = 'reservation' and discount_code_id is null and line_total_gross = 0
     and discount_amount is distinct from coalesce(v_full, 0);
  return null;
end $$;
drop trigger if exists reservations_annual_discount on booking.reservations;
create trigger reservations_annual_discount after insert or update of rule_id, persons, annual_card_id, order_item_id on booking.reservations
  for each row when (new.annual_card_id is not null) execute function booking._annual_res_discount_trg();

-- ---------------------------------------------------------------- 3) peruutus palauttaa käyttökerran, palautus ottaa sen takaisin
create or replace function booking._discount_release_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update booking.discount_codes set used_count = greatest(used_count - 1, 0) where id = new.discount_code_id;
  return null;
end $$;
drop trigger if exists orders_discount_release on booking.orders;
create trigger orders_discount_release after update of status on booking.orders
  for each row when (new.status in ('cancelled', 'expired') and old.status not in ('cancelled', 'expired') and new.discount_code_id is not null)
  execute function booking._discount_release_trg();

create or replace function booking._discount_reclaim_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update booking.discount_codes set used_count = used_count + 1 where id = new.discount_code_id;
  return null;
end $$;
drop trigger if exists orders_discount_reclaim on booking.orders;
create trigger orders_discount_reclaim after update of status on booking.orders
  for each row when (old.status in ('cancelled', 'expired') and new.status not in ('cancelled', 'expired') and new.discount_code_id is not null)
  execute function booking._discount_reclaim_trg();

-- ---------------------------------------------------------------- oikeudet (create or replace säilyttää vanhojen funktioiden oikeudet)
do $$
declare f text;
begin
  foreach f in array array['booking._code_rate_ok(text,text,text,text)', 'booking._annual_res_discount_trg()', 'booking._discount_reclaim_trg()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
