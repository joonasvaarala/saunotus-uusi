-- booking_330: Savusaunan musta viikko – jälkilöylyt ma–to -lahjakortti (130 €)
--
-- Joonas t1867u 21.11.2026: lahjakortti 130 €, käy jälkilöylyihin vain ma–to, lunastettaessa loppusumma
-- muuttuu vastaamaan lahjakorttia. Tuote julkaistaan vain linkkinä (ei kaupan listassa / sivuilla).
--
-- Muutokset:
--  1) gift_card_packages: listed (false = ei listata public_gift_card_packagesissa, ostettavissa suoralla linkillä),
--     redeem_product_ids / redeem_weekdays (ISO 1=ma … 7=su) / redeem_covers_base, redeem_note(+_en).
--  2) _gc_redeem_rules(order, card): rajaukset tarkistetaan ennen lunastusta. Jos redeem_covers_base, varausrivin
--     perushinta (fixed_plus_extra base, ei lisähenkilöitä/lisäpalveluita) lasketaan kortin arvoon (initial_amount):
--     discount_amount += base − arvo, price_breakdown.gift_cover. Kerran / rivi.
--  3) _gc_redeem kutsuu sitä (vain kun kortilla on package_code) ja lukee tilauksen uudelleen.
--  4) public_check_gift_card palauttaa restrictions; public_gift_card_packages suodattaa listed=false;
--     uusi public_gift_card_package(p_code) palauttaa yhden aktiivisen paketin myös listaamattomana (linkkisivu).
--  5) Paketti bf_jalkiloylyt_mato (130 €, 6 hlö, at_sale 25,5 %, 6 kk, listed=false) + FI-tekstit site_textsiin,
--     EN tyhjänä needs_translation=true (Kääntäjä).
-- Olemassa olevien pakettien ja korttien käytös ei muutu (uudet sarakkeet null/false, listed=true).

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table booking.gift_card_packages add column if not exists listed boolean not null default true;
alter table booking.gift_card_packages add column if not exists redeem_product_ids bigint[];
alter table booking.gift_card_packages add column if not exists redeem_weekdays smallint[];
alter table booking.gift_card_packages add column if not exists redeem_covers_base boolean not null default false;
alter table booking.gift_card_packages add column if not exists redeem_note text;
alter table booking.gift_card_packages add column if not exists redeem_note_en text;
alter table booking.gift_card_packages drop constraint if exists gift_card_packages_redeem_weekdays_check;
alter table booking.gift_card_packages add constraint gift_card_packages_redeem_weekdays_check
  check (redeem_weekdays is null or (cardinality(redeem_weekdays) between 1 and 7 and redeem_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]));
alter table booking.gift_card_packages drop constraint if exists gift_card_packages_redeem_products_check;
alter table booking.gift_card_packages add constraint gift_card_packages_redeem_products_check
  check (redeem_product_ids is null or cardinality(redeem_product_ids) >= 1);
alter table booking.gift_card_packages drop constraint if exists gift_card_packages_redeem_cover_check;
alter table booking.gift_card_packages add constraint gift_card_packages_redeem_cover_check
  check (not redeem_covers_base or (redeem_product_ids is not null and not is_open));
comment on column booking.gift_card_packages.listed is 'booking_330: false = ei public_gift_card_packages-listassa, myydään vain suoralla linkillä (public_gift_card_package)';
comment on column booking.gift_card_packages.redeem_weekdays is 'booking_330: ISO-viikonpäivät (1=ma … 7=su), joina varauksen alkaessa korttia voi käyttää; null = kaikki';
comment on column booking.gift_card_packages.redeem_covers_base is 'booking_330: lunastus laskee varausrivin perushinnan kortin arvoon (loppusumma = kortti + lisähenkilöt/lisät)';

create or replace function booking._gc_rules_json(p_code text) returns jsonb
language sql stable security definer set search_path to '' as $f$
  select case when p.redeem_product_ids is null and p.redeem_weekdays is null then null else
    jsonb_build_object('product_ids', to_jsonb(p.redeem_product_ids), 'weekdays', to_jsonb(p.redeem_weekdays),
      'covers_base', p.redeem_covers_base, 'note', p.redeem_note, 'note_en', p.redeem_note_en,
      'products', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'slug', k.slug, 'name', k.name, 'name_en', k.name_en) order by k.id), '[]'::jsonb)
                     from kb.products k where k.id = any (p.redeem_product_ids))) end
    from booking.gift_card_packages p where p.code = p_code
$f$;

create or replace function booking._gc_redeem_rules(p_order_id bigint, p_card_id bigint) returns numeric
language plpgsql security definer set search_path to '' as $f$
declare g booking.gift_cards; pk booking.gift_card_packages; it booking.order_items; v_pb jsonb; v_base numeric; v_amt numeric;
begin
  select * into g from booking.gift_cards where id = p_card_id;
  if g.package_code is null then return 0; end if;
  select * into pk from booking.gift_card_packages where code = g.package_code;
  if pk.code is null or (pk.redeem_product_ids is null and pk.redeem_weekdays is null) then return 0; end if;
  select oi.* into it
    from booking.order_items oi
    join booking.reservations r on r.order_item_id = oi.id and r.order_id = oi.order_id
   where oi.order_id = p_order_id and oi.kind = 'reservation'
     and r.status in ('pending', 'confirmed', 'completed')
     and (pk.redeem_product_ids is null or oi.product_id = any (pk.redeem_product_ids))
     and (pk.redeem_weekdays is null or extract(isodow from (r.starts_at at time zone booking._tz()))::int = any (pk.redeem_weekdays))
   order by (coalesce(oi.price_breakdown, '{}'::jsonb) ? 'gift_cover'), oi.id
   limit 1
   for update of oi;
  if it.id is null then
    perform booking._err('gift_card_not_applicable', coalesce(nullif(btrim(pk.redeem_note), ''), 'Lahjakortti ei käy tähän varaukseen'));
  end if;
  if not pk.redeem_covers_base or coalesce(it.price_breakdown, '{}'::jsonb) ? 'gift_cover' then return 0; end if;
  if it.discount_code_id is not null then
    perform booking._err('gift_card_not_applicable', 'Tätä lahjakorttia ei voi käyttää yhdessä alennuskoodin kanssa');
  end if;
  v_pb := coalesce(it.price_breakdown, '{}'::jsonb);
  v_base := case when v_pb ->> 'mode' = 'fixed_plus_extra' and coalesce(v_pb ->> 'base', '') ~ '^\d+(\.\d+)?$'
                 then (v_pb ->> 'base')::numeric - coalesce(nullif(v_pb #>> '{quiet,amount}', '')::numeric, 0)
                 else it.line_total_gross end;
  v_base := least(greatest(v_base, 0), coalesce(it.line_total_gross, 0));
  v_amt := round(greatest(v_base - g.initial_amount, 0), 2);
  if v_amt <= 0 then return 0; end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = coalesce(discount_amount, 0) + v_amt,
         price_breakdown = v_pb || jsonb_build_object('gift_cover', jsonb_build_object('gift_card_id', g.id, 'package', pk.code,
           'base', v_base, 'card_value', g.initial_amount, 'amount', v_amt, 'at', now()))
   where id = it.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.order_items', it.id::text, 'GIFT_CARD_COVER',
          jsonb_build_object('line_total_gross', it.line_total_gross, 'discount_amount', it.discount_amount),
          jsonb_build_object('order_id', p_order_id, 'gift_card_id', g.id, 'package', pk.code, 'base', v_base, 'card_value', g.initial_amount, 'amount', v_amt));
  return v_amt;
end $f$;

create or replace function booking.public_gift_card_package(p_code text) returns jsonb
language sql stable security definer set search_path to '' as $f$
  select coalesce((select jsonb_build_object('ok', true, 'sale_enabled', booking._gc_flag('gift_cards.sale_enabled'), 'redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'),
      'max_cards_per_order', (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int, 'currency', 'EUR',
      'package', jsonb_build_object('code', p.code, 'name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en,
        'kind', p.kind, 'is_open', p.is_open, 'price', p.price, 'min_amount', p.min_amount, 'max_amount', p.max_amount, 'persons', p.persons,
        'min_persons', p.min_persons, 'max_persons', p.max_persons,
        'unit_price', case when not p.is_open and p.items is not null and not exists (
            select 1 from jsonb_array_elements(p.items) it where coalesce(it ->> 'price_type', 'per_person') <> 'per_person' or it ->> 'unit_price' is null)
          then booking._gc_package_amount(p.items, 1) end,
        'vat_rate', p.vat_rate, 'valid_months', p.valid_months, 'items', p.items, 'listed', p.listed,
        'restrictions', booking._gc_rules_json(p.code)))
      from booking.gift_card_packages p
     where p.code = p_code and p.active and booking._gc_package_in_shop(p.code)),
    jsonb_build_object('ok', false, 'code', 'package_inactive', 'message', 'Paketti ei ole myynnissä'))
$f$;

revoke all on function booking._gc_rules_json(text) from public, anon, authenticated;
revoke all on function booking._gc_redeem_rules(bigint, bigint) from public, anon, authenticated;
grant execute on function booking._gc_rules_json(text) to service_role;
grant execute on function booking._gc_redeem_rules(bigint, bigint) to service_role;
revoke all on function booking.public_gift_card_package(text) from public;
grant execute on function booking.public_gift_card_package(text) to anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION booking._gc_redeem(p_order_id bigint, p_card_id bigint, p_amount numeric, p_note text, p_public boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; g booking.gift_cards; v_unpaid numeric; v_amt numeric; v_id bigint; rc record; v_excl boolean; v_card booking.gift_cards; v_rest numeric; v_confirmed boolean := false;
        v_own boolean; v_ok numeric; v_left numeric; v_use numeric; ur record;
begin
  if not booking._gc_flag('gift_cards.redeem_enabled') then perform booking._err('redeem_disabled', 'Lahjakorttien lunastus ei ole vielä käytössä'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if p_public and o.status = 'expired' then perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus'); end if;
  if p_public and o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_preliminary', 'Alustava varaus: maksu pyydetään vahvistuksen jälkeen'); end if;
  if p_public and o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now())
     and not booking._order_mp_inflight(o.id) then
    perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus');
  end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed') or (p_public and o.status = 'completed') then
    perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
  end if;
  if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;
  select * into g from booking.gift_cards where id = p_card_id for update;
  if not found then perform booking._err('gift_card_not_found', 'Korttia ei löydy'); end if;
  if g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then
    perform booking._err('johku_cards_closed', 'Johku-lähtöisten korttien lunastus ei ole vielä käytössä (kortit lunastetaan toistaiseksi Johkussa)');
  end if;
  if g.status in ('cancelled', 'pending_payment', 'pending_verification') then perform booking._err('gift_card_inactive', 'Kortti ei ole käytettävissä'); end if;
  if g.status = 'expired' or (g.valid_to is not null and g.valid_to < booking._gc_today()) then perform booking._err('gift_card_expired', 'Kortin voimassaolo on päättynyt'); end if;
  if g.status = 'used' or g.balance <= 0 then perform booking._err('gift_card_empty', 'Kortin saldo on käytetty'); end if;
  if not g.balance_verified then perform booking._err('gift_card_inactive', 'Kortin saldoa ei ole vahvistettu'); end if;
  -- booking_330: paketin lunastusrajaus (tuote + viikonpäivä) ja tuotteen perushinnan kattava kortti
  if g.package_code is not null and booking._gc_redeem_rules(o.id, g.id) > 0 then
    select * into o from booking.orders where id = o.id;
  end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
  v_amt := coalesce(p_amount, least(g.balance, v_unpaid));
  if v_amt is null or v_amt <= 0 or v_amt <> round(v_amt, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  if v_amt > g.balance + 0.004 then perform booking._err('insufficient_balance', format('Kortin saldo on %s €', g.balance)); end if;
  if v_amt > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  v_own := g.source is distinct from 'johku' and g.accounting_origin is distinct from 'johku';
  if v_own and not g.complimentary then
    select coalesce(sum(u.remaining) filter (where u.remaining > 0.004), 0)
      into v_ok from booking._order_uncovered(o.id, false) u;
    if v_amt > v_ok + 0.004 then
      perform booking._err('amount_exceeds_unpaid', 'Summa ylittää tuotteiden maksamattoman osuuden');
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu lahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, gift_card_id, note, created_by)
  values (o.id, 'gift_card', 'manual', 'pending', v_amt, g.id, nullif(concat_ws(' | ', 'Lahjakortti …' || right(g.code, 4), p_note), ''), auth.uid()) returning id into v_id;
  if v_own then
    v_left := v_amt;
    if abs(v_ok - v_amt) < 0.005 then
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select v_id, u.item_id, u.description, u.kind, u.quantity, u.remaining, u.vat_rate
        from booking._order_uncovered(o.id, false) u
       where u.remaining > 0.004;
    else
      for ur in select * from booking._order_uncovered(o.id, false) u where u.remaining > 0.004 loop
        exit when v_left <= 0.004;
        v_use := least(ur.remaining, v_left);
        insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
        values (v_id, ur.item_id, ur.description, ur.kind, case when v_use = ur.remaining then ur.quantity else 1 end, v_use, ur.vat_rate);
        v_left := v_left - v_use;
      end loop;
    end if;
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: tiedoksi-kuitti vain maksetulle omalle at_sale-kortille, ei kirjanpitoon
  perform booking._gc_apply(g.id, -v_amt, 'redemption', o.id, v_id, p_note);
  select * into v_card from booking.gift_cards where id = g.id;
  if v_card.single_order and v_card.balance > 0 then
    perform booking._gc_apply(g.id, -v_card.balance, 'single_order_forfeit', o.id, v_id, 'Kertakäyttökortti: jäännös ei käytettävissä');
    select * into v_card from booking.gift_cards where id = g.id;
  end if;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  v_rest := greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0);
  if o.status = 'pending' and v_rest <= 0.004 then
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
    v_confirmed := true;
  end if;
  v_excl := booking._acct_excluded(o.id, v_id);
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'amount', v_amt, 'order_id', o.id, 'balance', booking._order_balance(o.id),
    'gift_card', jsonb_build_object('id', v_card.id, 'code_last4', right(v_card.code, 4), 'balance', v_card.balance, 'status', v_card.status, 'valid_to', v_card.valid_to),
    'receipt_id', rc.id, 'receipt_no', rc.receipt_no, 'accounted', not v_excl,
    'confirmed', v_confirmed, 'remaining', v_rest, 'order_status', (select status from booking.orders where id = o.id));
end $function$;
CREATE OR REPLACE FUNCTION booking.public_check_gift_card(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_eff text; v_red boolean; v_why text;
begin
  if booking._gc_rl_blocked() then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_norm !~ '^[A-Z0-9]{12}$' then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found or g.status in ('cancelled', 'pending_payment') then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  perform booking._gc_log('ok');
  v_eff := case when g.status = 'active' and g.valid_to is not null and g.valid_to < booking._gc_today() then 'expired' else g.status end;
  v_why := case when not booking._gc_flag('gift_cards.redeem_enabled') then 'redeem_disabled'
                when g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then 'johku_cards_closed'
                when v_eff = 'expired' then 'expired' when v_eff = 'used' or g.balance <= 0 then 'empty'
                when v_eff = 'pending_verification' or not g.balance_verified then 'verification_pending' end;
  v_red := v_why is null and v_eff = 'active';
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'type', g.kind, 'package_code', g.package_code,
    'package_name', (select p.name from booking.gift_card_packages p where p.code = g.package_code), 'status', v_eff,
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_to', g.valid_to, 'redeemable', v_red, 'not_redeemable_reason', v_why,
    'balance_verified', g.balance_verified, 'restrictions', booking._gc_rules_json(g.package_code));  -- booking_330
end $function$;
CREATE OR REPLACE FUNCTION booking.public_gift_card_packages()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('ok', true, 'sale_enabled', booking._gc_flag('gift_cards.sale_enabled'), 'redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'),
    'max_cards_per_order', (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int, 'currency', 'EUR',
    'packages', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en,
        'kind', p.kind, 'is_open', p.is_open, 'price', p.price, 'min_amount', p.min_amount, 'max_amount', p.max_amount, 'persons', p.persons,
        'min_persons', p.min_persons, 'max_persons', p.max_persons,
        'unit_price', case when not p.is_open and p.items is not null and not exists (
            select 1 from jsonb_array_elements(p.items) it where coalesce(it ->> 'price_type', 'per_person') <> 'per_person' or it ->> 'unit_price' is null)
          then booking._gc_package_amount(p.items, 1) end,
        'vat_rate', p.vat_rate, 'valid_months', p.valid_months, 'items', p.items) order by p.sort_order, p.code)
      from booking.gift_card_packages p where p.active and p.listed and booking._gc_package_in_shop(p.code)), '[]'::jsonb))  -- booking_330: listed=false → vain suoralla linkillä  -- booking_316: Lahjakorttikauppa-kanava
$function$;

-- Paketti
do $m330$
declare v_pid bigint;
begin
  select id into v_pid from kb.products where slug = 'jalkiloylyt';
  if v_pid is null then raise exception 'booking_330: tuotetta jalkiloylyt ei löydy. Ei muutoksia.'; end if;
  if (select price from kb.products where id = v_pid) is distinct from 180.00
     or (select included_persons from kb.products where id = v_pid) is distinct from 6 then
    raise exception 'booking_330: jälkilöylyjen hinta/sis. henkilöt muuttuneet (odotettu 180 € / 6). Ei muutoksia.';
  end if;
  insert into booking.gift_card_packages(code, name, name_en, description, description_en, kind, is_open, price, min_amount, max_amount,
      persons, min_persons, max_persons, vat_rate, vat_treatment, kb_product_id, items, valid_months, active, sort_order,
      listed, redeem_product_ids, redeem_weekdays, redeem_covers_base, redeem_note, redeem_note_en)
  values ('bf_jalkiloylyt_mato',
    'Savusaunan jälkilöylyt ma–to -lahjakortti',
    null,
    'Savusaunan musta viikko: lahjakortti savusaunan jälkilöylyihin maanantaista torstaihin. Kortilla varataan kahden tunnin jälkilöylyt, ja hintaan sisältyy enintään 6 henkeä (lisähenkilöt 10 €/hlö). Lunastettaessa kortti kattaa jälkilöylyjen perushinnan kokonaan. Kortti käy vain ma–to alkaviin jälkilöylyihin.',
    null,
    'product', false, 130.00, null, null,
    6, null, null, 25.50, 'at_sale', null,
    jsonb_build_array(jsonb_build_object('label', 'Savusaunan jälkilöylyt ma–to (2 h, sis. 6 henkeä)')),
    6, true, 60,
    false, array[v_pid], array[1,2,3,4]::smallint[], true,
    'Tämä lahjakortti käy vain savusaunan jälkilöylyihin maanantaista torstaihin.', null)
  on conflict (code) do nothing;

  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'name', 'name', $$'fi'$$, $$'normal'$$, $$s.code = 'bf_jalkiloylyt_mato'$$, 200);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'name', 'name_en', $$'en'$$, $$'normal'$$, $$s.code = 'bf_jalkiloylyt_mato'$$, 200);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'description', 'description', $$'fi'$$, $$'normal'$$, $$s.code = 'bf_jalkiloylyt_mato'$$, 2000);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'description', 'description_en', $$'en'$$, $$'normal'$$, $$s.code = 'bf_jalkiloylyt_mato'$$, 2000);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'redeem_note', 'redeem_note', $$'fi'$$, $$'normal'$$, $$s.code = 'bf_jalkiloylyt_mato'$$, 300);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'redeem_note', 'redeem_note_en', $$'en'$$, $$'normal'$$, $$s.code = 'bf_jalkiloylyt_mato'$$, 300);
  update booking.site_texts set needs_translation = true
   where source_table = 'booking.gift_card_packages' and source_pk = 'bf_jalkiloylyt_mato' and lang = 'en';
end
$m330$;

notify pgrst, 'reload schema';
