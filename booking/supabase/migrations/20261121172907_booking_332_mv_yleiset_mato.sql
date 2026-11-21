-- booking_332: Savusaunan musta viikko – yleisten vuorojen lahjakortti 2 hengelle (50 €), ma–to, voi käyttää kahdessa osassa.
--
-- Joonas t1871u 21.11.2026. Sama mekanismi kuin booking_330/331 (bf_jalkiloylyt_mato), lisänä henkilöpääsytila:
--  - gift_card_packages.redeem_unit_value: yhden pääsyn osuus kortin arvosta (50 € / 2 = 25 €). Kun asetettu,
--    redeem_cover_max on henkilökohtainen katto (29 € = tavallinen yleisen vuoron henkilöhinta).
--  - Lunastus: kortti kattaa riviltä n = min(kattamattomat henkilöt, floor(saldo / 25)) henkilöä. Henkilöhinta
--    (enintään 29 €) lasketaan 25 €:oon (discount_amount += n × (min(hinta, 29) − 25)) ja kortti maksaa n × 25 €.
--    Merkintä price_breakdown.gift_covers[] (useita kortteja / osakäyttöä varten).
--  - _gc_redeem_cap: kortin enimmäissumma tilaukselle = katettujen pääsyjen card_amount − kortilla jo maksettu,
--    jotta saldoa ei kulu lisäpalveluihin tai lisähenkilöihin. Kortin saldo = jäljellä olevat pääsyt × 25 €,
--    joten palautus kortille (peruutus) palauttaa myös pääsyn.
--  - Kortin arvo on myyntihinta 50 € (at_sale, kuten muilla), ei 58 €: saldo ja myynti täsmäävät raporteissa.
-- Olemassa olevien pakettien/korttien käytös ei muutu (redeem_unit_value null → vanha polku).

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table booking.gift_card_packages add column if not exists redeem_unit_value numeric(10,2);
alter table booking.gift_card_packages drop constraint if exists gift_card_packages_redeem_unit_value_check;
alter table booking.gift_card_packages add constraint gift_card_packages_redeem_unit_value_check
  check (redeem_unit_value is null or (redeem_unit_value > 0 and redeem_covers_base and not is_open));
comment on column booking.gift_card_packages.redeem_unit_value is 'booking_332: henkilöpääsykortti – yhden pääsyn osuus kortin arvosta; redeem_cover_max on silloin katto / hlö';

create or replace function booking._gc_redeem_cap(p_order_id bigint, p_card_id bigint) returns numeric
language sql stable security definer set search_path to '' as $f$
  select case when pk.redeem_unit_value is null then null else
    greatest(
      coalesce((select sum((x ->> 'card_amount')::numeric)
                  from booking.order_items oi
                  cross join lateral jsonb_array_elements(coalesce(oi.price_breakdown -> 'gift_covers', '[]'::jsonb)) x
                 where oi.order_id = p_order_id and (x ->> 'gift_card_id')::bigint = p_card_id), 0)
      - coalesce((select sum(p.amount) from booking.payments p
                   where p.order_id = p_order_id and p.gift_card_id = p_card_id and p.status = 'paid'), 0), 0) end
    from booking.gift_cards g join booking.gift_card_packages pk on pk.code = g.package_code
   where g.id = p_card_id
$f$;
revoke all on function booking._gc_redeem_cap(bigint, bigint) from public, anon, authenticated;
grant execute on function booking._gc_redeem_cap(bigint, bigint) to service_role;

CREATE OR REPLACE FUNCTION booking._gc_redeem_rules(p_order_id bigint, p_card_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g booking.gift_cards; pk booking.gift_card_packages; it booking.order_items; v_pb jsonb; v_base numeric; v_amt numeric;
        v_iid bigint; v_persons int; v_used int; v_left_uses int; v_n int; v_unit numeric; v_cov numeric; v_card_amt numeric;  -- booking_332
begin
  select * into g from booking.gift_cards where id = p_card_id;
  if g.package_code is null then return 0; end if;
  select * into pk from booking.gift_card_packages where code = g.package_code;
  if pk.code is null or (pk.redeem_product_ids is null and pk.redeem_weekdays is null) then return 0; end if;
  select oi.id, r.persons into v_iid, v_persons
    from booking.order_items oi
    join booking.reservations r on r.order_item_id = oi.id and r.order_id = oi.order_id
   where oi.order_id = p_order_id and oi.kind = 'reservation'
     and r.status in ('pending', 'confirmed', 'completed')
     and (pk.redeem_product_ids is null or oi.product_id = any (pk.redeem_product_ids))
     and (pk.redeem_weekdays is null or extract(isodow from (r.starts_at at time zone booking._tz()))::int = any (pk.redeem_weekdays))
   order by (coalesce(oi.price_breakdown, '{}'::jsonb) ? 'gift_cover'),
            -- booking_332: henkilöpääsykortit – ensin rivi, jolla on vielä kattamattomia henkilöitä
            (coalesce((select sum((x ->> 'uses')::int) from jsonb_array_elements(coalesce(oi.price_breakdown -> 'gift_covers', '[]'::jsonb)) x), 0) >= coalesce(r.persons, 0)),
            oi.id
   limit 1
   for update of oi;
  if v_iid is not null then select * into it from booking.order_items where id = v_iid; end if;
  if it.id is null then
    perform booking._err('gift_card_not_applicable', coalesce(nullif(btrim(pk.redeem_note), ''), 'Lahjakortti ei käy tähän varaukseen'));
  end if;
  -- booking_332: henkilöpääsykortti (redeem_unit_value = yhden pääsyn osuus kortin arvosta, esim. 50 € / 2 = 25 €).
  -- Kortti kattaa enintään floor(saldo / unit_value) henkilöä tältä riviltä; henkilöhinta lasketaan katon
  -- (redeem_cover_max / hlö) mukaan unit_valueen. Lisähenkilöt ja katon ylittävä osa maksetaan itse.
  if pk.redeem_unit_value is not null and pk.redeem_covers_base then
    if it.discount_code_id is not null then
      perform booking._err('gift_card_not_applicable', 'Tätä lahjakorttia ei voi käyttää yhdessä alennuskoodin kanssa');
    end if;
    v_pb := coalesce(it.price_breakdown, '{}'::jsonb);
    v_persons := greatest(coalesce(v_persons, nullif(v_pb ->> 'persons', '')::int, it.quantity, 1), 1);
    v_used := coalesce((select sum((x ->> 'uses')::int) from jsonb_array_elements(coalesce(v_pb -> 'gift_covers', '[]'::jsonb)) x), 0);
    v_left_uses := floor((g.balance + 0.004) / pk.redeem_unit_value)::int;
    if v_left_uses < 1 then perform booking._err('gift_card_empty', 'Kortin pääsyt on jo käytetty'); end if;
    v_n := least(greatest(v_persons - v_used, 0), v_left_uses);
    if v_n < 1 then perform booking._err('gift_card_not_applicable', 'Varauksen kaikki henkilöt on jo katettu lahjakortilla'); end if;
    v_unit := case when coalesce(v_pb ->> 'unit_price', '') ~ '^\d+(\.\d+)?$' then (v_pb ->> 'unit_price')::numeric else it.line_total_gross / v_persons end;
    v_unit := least(v_unit, it.line_total_gross / v_persons);
    v_cov := least(v_unit, coalesce(pk.redeem_cover_max, v_unit));
    v_card_amt := round(v_n * least(v_cov, pk.redeem_unit_value), 2);
    v_amt := round(v_n * greatest(v_cov - pk.redeem_unit_value, 0), 2);
    update booking.order_items
       set line_total_gross = line_total_gross - v_amt, discount_amount = coalesce(discount_amount, 0) + v_amt,
           price_breakdown = v_pb || jsonb_build_object('gift_covers', coalesce(v_pb -> 'gift_covers', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
             'gift_card_id', g.id, 'package', pk.code, 'uses', v_n, 'unit', v_unit, 'cover_max', pk.redeem_cover_max, 'unit_value', pk.redeem_unit_value,
             'amount', v_amt, 'card_amount', v_card_amt, 'at', now())))
     where id = it.id;
    if v_amt > 0 then update booking.orders set total_gross = total_gross - v_amt where id = p_order_id; end if;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.order_items', it.id::text, 'GIFT_CARD_COVER',
            jsonb_build_object('line_total_gross', it.line_total_gross, 'discount_amount', it.discount_amount),
            jsonb_build_object('order_id', p_order_id, 'gift_card_id', g.id, 'package', pk.code, 'uses', v_n, 'unit', v_unit,
                               'cover_max', pk.redeem_cover_max, 'unit_value', pk.redeem_unit_value, 'amount', v_amt, 'card_amount', v_card_amt));
    return v_amt;
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
  -- booking_331: katto (esim. ma–to 2 h 180 €). Kalliimmassa vuorossa (joulu 24.–30.12.) asiakas maksaa erotuksen.
  v_amt := round(greatest(least(v_base, coalesce(pk.redeem_cover_max, v_base)) - g.initial_amount, 0), 2);
  if v_amt <= 0 then return 0; end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = coalesce(discount_amount, 0) + v_amt,
         price_breakdown = v_pb || jsonb_build_object('gift_cover', jsonb_build_object('gift_card_id', g.id, 'package', pk.code,
           'base', v_base, 'cover_max', pk.redeem_cover_max, 'card_value', g.initial_amount, 'amount', v_amt, 'at', now()))
   where id = it.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.order_items', it.id::text, 'GIFT_CARD_COVER',
          jsonb_build_object('line_total_gross', it.line_total_gross, 'discount_amount', it.discount_amount),
          jsonb_build_object('order_id', p_order_id, 'gift_card_id', g.id, 'package', pk.code, 'base', v_base, 'cover_max', pk.redeem_cover_max, 'card_value', g.initial_amount, 'amount', v_amt));
  return v_amt;
end $function$;
CREATE OR REPLACE FUNCTION booking._gc_redeem(p_order_id bigint, p_card_id bigint, p_amount numeric, p_note text, p_public boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; g booking.gift_cards; v_unpaid numeric; v_amt numeric; v_id bigint; rc record; v_excl boolean; v_card booking.gift_cards; v_rest numeric; v_confirmed boolean := false;
        v_own boolean; v_ok numeric; v_left numeric; v_use numeric; ur record; v_cap numeric;
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
  v_cap := case when g.package_code is not null then booking._gc_redeem_cap(o.id, g.id) end;   -- booking_332: henkilöpääsykortin enimmäissumma
  v_amt := coalesce(p_amount, least(g.balance, v_unpaid, coalesce(v_cap, g.balance)));
  if v_cap is not null and v_amt > v_cap + 0.004 then
    perform booking._err('amount_exceeds_unpaid', format('Kortilla voi maksaa tästä varauksesta enintään %s €', v_cap));
  end if;
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
CREATE OR REPLACE FUNCTION booking._gc_rules_json(p_code text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case when p.redeem_product_ids is null and p.redeem_weekdays is null then null else
    jsonb_build_object('product_ids', to_jsonb(p.redeem_product_ids), 'weekdays', to_jsonb(p.redeem_weekdays),
      'covers_base', p.redeem_covers_base, 'cover_max', p.redeem_cover_max, 'unit_value', p.redeem_unit_value, 'note', p.redeem_note, 'note_en', p.redeem_note_en,
      'products', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'slug', k.slug, 'name', k.name, 'name_en', k.name_en) order by k.id), '[]'::jsonb)
                     from kb.products k where k.id = any (p.redeem_product_ids))) end
    from booking.gift_card_packages p where p.code = p_code
$function$;

do $m332$
declare v_ids bigint[]; v_n int;
begin
  select array_agg(id order by id), count(*) into v_ids, v_n from kb.products
   where slug in ('yleinensauna', 'miestensauna-2', 'naistensauna', 'hiljainen-sauna', 'turvetorstai') and active;
  if v_n <> 5 then raise exception 'booking_332: yleisten vuorojen tuotteita löytyi % (odotettu 5). Ei muutoksia.', v_n; end if;
  if exists (select 1 from kb.products where slug in ('yleinensauna', 'miestensauna-2', 'naistensauna', 'hiljainen-sauna') and price is distinct from 29.00) then
    raise exception 'booking_332: yleisen vuoron henkilöhinta ei ole 29 €. Ei muutoksia.';
  end if;
  insert into booking.gift_card_packages(code, name, name_en, description, description_en, kind, is_open, price, min_amount, max_amount,
      persons, min_persons, max_persons, vat_rate, vat_treatment, kb_product_id, items, valid_months, active, sort_order,
      listed, redeem_product_ids, redeem_weekdays, redeem_covers_base, redeem_cover_max, redeem_unit_value, redeem_note, redeem_note_en)
  values ('mv_yleiset_mato', 'Yleisten vuorojen lahjakortti 2 hengelle', null, 'Savusaunan musta viikko', null,
    'product', false, 50.00, null, null,
    2, null, null, 25.50, 'at_sale', null,
    jsonb_build_array(jsonb_build_object('label', '2 × pääsy yleiselle vuorolle ma–to')),
    6, true, 61,
    false, v_ids, array[1,2,3,4]::smallint[], true, 29.00, 25.00,
    'Voimassa 6 kk, ma–to. 2 henkeä, voi käyttää kahdessa osassa.', null)
  on conflict (code) do nothing;

  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'name', 'name', $$'fi'$$, $$'normal'$$, $$s.code = 'mv_yleiset_mato'$$, 200);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'name', 'name_en', $$'en'$$, $$'normal'$$, $$s.code = 'mv_yleiset_mato'$$, 200);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'description', 'description', $$'fi'$$, $$'normal'$$, $$s.code = 'mv_yleiset_mato'$$, 2000);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'description', 'description_en', $$'en'$$, $$'normal'$$, $$s.code = 'mv_yleiset_mato'$$, 2000);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'redeem_note', 'redeem_note', $$'fi'$$, $$'normal'$$, $$s.code = 'mv_yleiset_mato'$$, 300);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'redeem_note', 'redeem_note_en', $$'en'$$, $$'normal'$$, $$s.code = 'mv_yleiset_mato'$$, 300);
  update booking.site_texts set needs_translation = true
   where source_table = 'booking.gift_card_packages' and source_pk = 'mv_yleiset_mato' and lang = 'en';

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  select null, 'bot', 'booking.gift_card_packages', 'mv_yleiset_mato', 'GIFT_PACKAGE_CREATE', null,
         to_jsonb(p) || jsonb_build_object('by', 'Bottiavustus', 'reason', 'Joonas t1871u: musta viikko, yleiset vuorot ma–to 2 hlö 50 €', 'migration', 'booking_332')
    from booking.gift_card_packages p where p.code = 'mv_yleiset_mato';
end
$m332$;

notify pgrst, 'reload schema';
