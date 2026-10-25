-- booking_180: booking.admin_set_reservation_addons(bigint,jsonb) suojaa maksetut lisäpalvelurivit ja avoimien verkkomaksulinkkien rivit.
-- VÄLIAIKAINEN versio 20261026090000 (tuotannon versio voi olla eri; Bottiavustus ajaa). Ei public-skeemaa, ei taulumuutoksia, ei datamuutoksia: vain CREATE OR REPLACE.
--
-- Ennen: funktio poisti kaikki varauksen lisäpalvelurivit ja liitti syötteen uudelleen. Maksetun rivin payment_lines.order_item_id
-- nollautui (FK ON DELETE SET NULL), rivi luotiin uudelleen kattamattomana ja uusi maksulinkki olisi veloittanut sen toiseen kertaan.
-- Nyt:
--  * Lukittu rivi = maksetuissa maksuissa (paid / partially_refunded / refunded) nettokatetta sum(amount_gross - refunded_gross) > 0
--    TAI rivi on avoimella verkkomaksulinkillä (pending, provider <> manual). Pending manual (pay_later, invoice) ei lukitse:
--    niillä ei ole maksurivejä ennen admin_record_payment-kirjausta, joka tehdään samassa transaktiossa.
--  * Kokonaan hyvitetty rivi ei ole lukittu: sen voi poistaa kuten ennen (muuten tilaus jäisi maksamattomaksi hyvitetyn verran).
--  * Lukitut rivit säilyvät (sama id, hinta ja maksurivi); lukitun määrän alittava pyyntö -> addon_link_open / addon_paid ennen mitään muutosta.
--    Pyydetty lisäys liitetään erotuksena uudeksi riviksi _attach_addons-funktiolla.
--  * Enimmäismäärä tarkistetaan pyydetystä kokonaismäärästä, mutta vähintään lukittu määrä kelpaa aina (henkilömäärä tai max_per_person
--    on voinut laskea maksun jälkeen).
--  * Ei lukittuja rivejä -> täsmälleen vanha polku (kaikki rivit pois, syöte sellaisenaan _attach_addons-funktiolle).
--  * Tilaus lukitaan FOR UPDATE heti varauksen jälkeen (sama lukko kuin _create_link_payment, mobilepay/vismapay_payment_prepare,
--    admin_record_payment ja admin_refund), joten lukitustarkistus näkee rinnakkaisen linkin/maksun commitoidut rivit.
--  * Audit-loki: new_data saa avaimet locked ja added vain, kun lukittuja rivejä oli.
--
-- Vartija: md5(pg_get_functiondef(booking.admin_set_reservation_addons(bigint,jsonb))) on oltava tuotannon 3a9ec1b6cb0358977d970fdb2886f46e
-- (tai jo tämän migraation 55897305ec87eb5a0c016154aa275107), muuten ajo keskeytyy eikä mitään muuteta. Uudelleenajettava.
-- Tuotannon md5 ennen (luettu sxbofnuisemspgquoxyv 26.10.2026; rollback palauttaa tämän täsmälleen): 3a9ec1b6cb0358977d970fdb2886f46e
-- Tämän migraation jälkeen: 55897305ec87eb5a0c016154aa275107. SECURITY DEFINER, search_path '', oikeudet ennallaan (authenticated, service_role; ei public/anon).
-- Muut funktiot ennallaan: _attach_addons 319cac689b7c883bbba857af6b254a3f, _addon_limit 8addb644ba4d21644192df98576aad0a,
-- _sync_placeholder 08c2adec0b15d12118ac6d0bcd67b573, _refresh_order_payment 84e6c0a9c5ed6eb64234e8cdf859fbff.
-- Rollback: rollbacks/20261026090000_booking_180_ROLLBACK.sql. Testi: tests/talous/t180_addons_paid_guard.sql (paikallinen PG17, fixtures/10_test_helpers.sql).
set local lock_timeout = '5s';

do $g$
declare v_md5 text := (select md5(pg_get_functiondef('booking.admin_set_reservation_addons(bigint,jsonb)'::regprocedure)));
begin
  if v_md5 not in ('3a9ec1b6cb0358977d970fdb2886f46e', '55897305ec87eb5a0c016154aa275107') then
    raise exception 'booking_180: booking.admin_set_reservation_addons md5 % ei ole odotettu (3a9ec1b6cb0358977d970fdb2886f46e / 55897305ec87eb5a0c016154aa275107); mitään ei muutettu', v_md5;
  end if;
end $g$;

create or replace function booking.admin_set_reservation_addons(p_reservation_id bigint, p_addons jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  res booking.reservations;
  a booking.addons;
  e jsonb;
  l record;
  v_old jsonb;
  v_total numeric;
  v_locked jsonb := '[]'::jsonb;
  v_added jsonb := '[]'::jsonb;
  v_acc jsonb := '{}'::jsonb;
  v_extra jsonb := '{}'::jsonb;
  v_lockq jsonb := '{}'::jsonb;
  v_rituals jsonb := '[]'::jsonb;
  v_attach jsonb;
  v_idtxt text;
  v_code text;
  v_key text;
  v_qty integer;
  v_lim integer;
  v_kept_ids bigint[] := '{}'::bigint[];
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if res.status not in ('pending','confirmed') then perform booking._err('not_editable', 'Lisäpalveluita voi muuttaa vain voimassa olevaan varaukseen'); end if;

  -- booking_180: sama tilauslukko kuin maksulinkin luonnissa, käsimaksussa ja hyvityksessä; alla olevat lauseet näkevät niiden commitoidut rivit.
  perform 1 from booking.orders where id = res.order_id for update;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', product_name, 'quantity', quantity) order by id), '[]'::jsonb)
    into v_old from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';

  -- Lukittu rivi: maksetuissa maksuissa nettokatetta (amount_gross - refunded_gross > 0) tai avoin verkkomaksulinkki.
  -- Kokonaan hyvitetty rivi ei ole lukittu (vanha käytös: rivin voi poistaa, tilauksen summa laskee hyvitetyn verran).
  for l in
    select i.id, i.addon_id, i.quantity,
      coalesce((select sum(pl.amount_gross - pl.refunded_gross) from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                 where pl.order_item_id = i.id and p.status in ('paid','partially_refunded','refunded')), 0) > 0.004 as has_paid,
      exists (select 1 from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
               where pl.order_item_id = i.id and p.status = 'pending' and p.provider <> 'manual') as has_link
    from booking.order_items i
    where i.parent_item_id = res.order_item_id and i.kind = 'addon'
    order by i.id for update of i
  loop
    continue when not l.has_paid and not l.has_link;
    v_locked := v_locked || jsonb_build_array(jsonb_build_object('item_id', l.id, 'addon_id', l.addon_id,
                      'quantity', l.quantity, 'paid', l.has_paid, 'link_open', l.has_link));
  end loop;

  if jsonb_array_length(v_locked) = 0 then
    -- Ei lukittuja rivejä: täsmälleen vanha polku (kaikki rivit pois, syöte sellaisenaan _attach_addons-funktiolle).
    v_attach := p_addons;
  else
    -- Normalisoi pyydetty kokonaismäärä per lisäpalvelu; ritual_start-elementit sellaisenaan.
    if p_addons is not null and p_addons <> 'null'::jsonb then
      if jsonb_typeof(p_addons) <> 'array' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
      if jsonb_array_length(p_addons) > 20 then perform booking._err('invalid_addons', 'Liian monta lisäpalvelua'); end if;
      for e in select x from pg_catalog.jsonb_array_elements(p_addons) x loop
        if jsonb_typeof(e) = 'object' and e ? 'ritual_start' then v_rituals := v_rituals || jsonb_build_array(e); continue; end if;
        if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
        v_idtxt := e ->> 'id'; v_code := e ->> 'code';
        if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
        v_qty := (e ->> 'quantity')::integer;
        if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
        select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
        if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
        v_acc := jsonb_set(v_acc, array[a.id::text], to_jsonb(coalesce((v_acc ->> a.id::text)::integer, 0) + v_qty));
      end loop;
    end if;
    v_extra := v_acc;

    -- Vähennys lukitun määrän alle hylätään ennen yhtään muutosta.
    for l in
      select x.addon_id, sum(x.quantity)::integer as quantity, bool_or(x.link_open) as link_open
        from pg_catalog.jsonb_to_recordset(v_locked) as x(item_id bigint, addon_id bigint, quantity integer, paid boolean, link_open boolean)
       group by x.addon_id order by x.addon_id
    loop
      v_qty := coalesce((v_acc ->> l.addon_id::text)::integer, 0);
      if v_qty < l.quantity then
        if l.link_open then perform booking._err('addon_link_open', 'Lisäpalvelu on avoimella maksulinkillä. Odota maksua tai linkin vanhenemista.'); end if;
        perform booking._err('addon_paid', 'Lisäpalvelu on jo maksettu. Hyvitä se ensin tilausnäkymässä.');
      end if;
      v_lockq := jsonb_set(v_lockq, array[l.addon_id::text], to_jsonb(l.quantity));
      v_extra := jsonb_set(v_extra, array[l.addon_id::text], to_jsonb(v_qty - l.quantity));
    end loop;

    -- Enimmäismäärä koskee pyydettyä kokonaismäärää. Jo lukittu määrä kelpaa aina, vaikka henkilömäärä
    -- tai max_per_person olisi myöhemmin laskenut (muuten varausta ei voisi tallentaa eikä vähentää).
    for v_key, v_qty in select k, (v_acc ->> k)::integer from pg_catalog.jsonb_object_keys(v_acc) k order by k::bigint loop
      select * into a from booking.addons where id = v_key::bigint;
      v_lim := booking._addon_limit(a.max_per_person, res.persons);
      if v_qty > greatest(v_lim, coalesce((v_lockq ->> v_key)::integer, 0)) then
        perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi valita enintään %s kpl', a.name, greatest(v_lim, coalesce((v_lockq ->> v_key)::integer, 0))));
      end if;
    end loop;

    -- Lukitut rivit säilyvät; liitetään vain positiiviset erotukset (ja ritual_start-elementit).
    v_attach := v_rituals;
    for v_key, v_qty in select k, (v_extra ->> k)::integer from pg_catalog.jsonb_object_keys(v_extra) k order by k::bigint loop
      if v_qty > 0 then v_attach := v_attach || jsonb_build_array(jsonb_build_object('id', v_key::bigint, 'quantity', v_qty)); end if;
    end loop;
  end if;

  delete from booking.order_items i
   where i.parent_item_id = res.order_item_id and i.kind = 'addon'
     and not (i.id = any (select (x ->> 'item_id')::bigint from pg_catalog.jsonb_array_elements(v_locked) x));
  select coalesce(array_agg(i.id), '{}'::bigint[]) into v_kept_ids from booking.order_items i
   where i.parent_item_id = res.order_item_id and i.kind = 'addon';
  update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = res.order_id), 0) where id = res.order_id;
  perform booking._attach_addons(res.id, v_attach);
  select coalesce(jsonb_agg(jsonb_build_object('item_id', i.id, 'addon_id', i.addon_id, 'quantity', i.quantity) order by i.id), '[]'::jsonb)
    into v_added from booking.order_items i where i.parent_item_id = res.order_item_id and i.kind = 'addon' and not i.id = any (v_kept_ids);
  select total_gross into v_total from booking.orders where id = res.order_id;
  if v_total < (select coalesce(sum(p.amount), 0) - coalesce(sum(p.refunded_amount), 0) from booking.payments p
                 where p.order_id = res.order_id and p.status in ('paid','partially_refunded','refunded')) then
    perform booking._err('below_paid', 'Tilauksen summa ei voi laskea alle maksetun summan (hyvitä ensin)');
  end if;
  perform booking._sync_placeholder(res.order_id);
  perform booking._refresh_order_payment(res.order_id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'order_items', res.order_id::text, 'ADMIN_SET_ADDONS', jsonb_build_object('addons', v_old),
          jsonb_build_object('addons', coalesce(p_addons, '[]'::jsonb), 'total', v_total)
          || case when jsonb_array_length(v_locked) > 0 then jsonb_build_object('locked', v_locked, 'added', v_added) else '{}'::jsonb end);
  return jsonb_build_object('ok', true, 'total', v_total);
end $function$;

revoke all on function booking.admin_set_reservation_addons(bigint, jsonb) from public, anon;
grant execute on function booking.admin_set_reservation_addons(bigint, jsonb) to authenticated, service_role;
