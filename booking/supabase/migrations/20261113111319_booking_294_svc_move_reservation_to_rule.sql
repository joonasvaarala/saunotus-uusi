-- booking_294: svc_move_reservation_to_rule
-- Siirtää vahvistetun/maksetun tilauksen varauksen toiseen schedule_rules-sääntöön (myös toiseen tuotteeseen)
-- niin, että tilauksen summa, rivit, ALV ja maksut pysyvät ennallaan.
-- Ei maksulinkkiä, ei hyvitystä, ei sähköpostia/asiakasviestiä. p_preview=true (oletus) ei muuta mitään.
-- Tukee vain julkaistusta säännöstä sääntöön (ajastetut varaukset, joilla ei ole legejä eikä lisäpalveluvarauksia).
-- Kapasiteetti, päällekkäisyys ja sulku tarkistetaan samoilla funktioilla kuin reservations_validate (_check_claim, _rule_closure_exempt).
-- Joonas 13.11.2026 (t214u Työvuoro-Tapio): naisten saunan osallistujat joulusaunaan vanhalla hinnalla.

create or replace function booking.svc_move_reservation_to_rule(
  p_order_no bigint,
  p_reservation_id bigint,
  p_rule_id bigint,
  p_starts_at timestamptz,
  p_note text,
  p_requested_by text,
  p_actor text default 'Asiakaspalvelu',
  p_preview boolean default true
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  o booking.orders;
  res booking.reservations;
  rs record;
  v_actor text;
  v_note text;
  v_req text;
  v_preview boolean := coalesce(p_preview, true);
  v_today date;
  v_date date;
  v_horizon integer;
  v_code text;
  v_msg text;
  v_pools bigint[];
  v_sess text;
  v_total numeric;
  v_price_sig text;
  v_item booking.order_items;
  v_old_prod_name text;
  v_new_prod_name text;
  v_old_rule_label text;
  v_new_rule_label text;
  v_target_price numeric;
  v_line text;
  v_old jsonb;
  v_plan jsonb;
begin
  perform booking._clear_staff_overrides();
  perform set_config('booking.svc_overbook', 'off', true);
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_req := nullif(btrim(coalesce(p_requested_by, '')), '');
  v_today := (now() at time zone booking._tz())::date;
  v_horizon := coalesce((booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int, 120);

  if p_order_no is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if p_reservation_id is null then perform booking._err('no_reservation', 'Anna varauksen id (p_reservation_id)'); end if;
  if p_rule_id is null then perform booking._err('rule_not_found', 'Anna kohdesääntö (p_rule_id)'); end if;
  if p_starts_at is null then perform booking._err('invalid_time', 'Anna kohdesession alkuaika (p_starts_at)'); end if;
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if v_req is null then perform booking._err('requested_by_required', 'Anna pyytäjän/hyväksyjän viite (p_requested_by)'); end if;
  if p_starts_at <= now() then perform booking._err('not_in_future', 'Kohdevuoron pitää alkaa tulevaisuudessa'); end if;
  v_date := (p_starts_at at time zone booking._tz())::date;
  if v_date > v_today + v_horizon then
    perform booking._err('beyond_horizon', format('Kohdevuoron pitää olla enintään %s päivän päässä', v_horizon));
  end if;

  select * into o from booking.orders where order_no = p_order_no;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;

  -- Lukitusjärjestys kuten svc_move_reservation: ensin varaus, sitten tilaus.
  select * into res from booking.reservations r where r.id = p_reservation_id for update;
  if not found or res.order_id is distinct from o.id then
    perform booking._err('reservation_not_in_order', 'Varaus ei kuulu tälle tilaukselle');
  end if;
  select * into o from booking.orders where id = o.id for update;

  if o.status in ('cancelled', 'expired') then
    perform booking._err('order_cancelled', 'Peruttua tilausta ei voi siirtää');
  end if;
  if not (o.status = 'confirmed' or o.payment_status = 'paid') then
    perform booking._err('not_changeable', 'Vain vahvistetun tai maksetun tilauksen varauksen voi siirtää');
  end if;
  if res.status <> 'confirmed' or res.hidden_at is not null then
    perform booking._err('not_changeable', 'Vain vahvistetun (näkyvän) varauksen voi siirtää');
  end if;
  if res.parent_reservation_id is not null then
    perform booking._err('unsupported', 'Lisäpalveluvarausta ei voi siirtää tällä toiminnolla');
  end if;
  if res.checkin_at is not null then
    perform booking._err('already_checked_in', 'Sisäänkirjattua varausta ei voi siirtää');
  end if;
  if res.annual_card_id is not null then
    perform booking._err('unsupported', 'Vuosikorttivarausta ei siirretä tällä toiminnolla (hinta lasketaan säännöstä)');
  end if;
  if res.product_option_id is not null then
    perform booking._err('unsupported', 'Varauksella on tuotevalinta; siirrä hallinnan kautta');
  end if;
  if exists (select 1 from booking.reservation_legs l where l.reservation_id = res.id) then
    perform booking._err('unsupported', 'Varauksella on resurssilegejä (hoito/rituaali); siirrä hallinnan kautta');
  end if;
  if exists (select 1 from booking.reservations c where c.parent_reservation_id = res.id
              and c.status in ('pending', 'confirmed') and c.hidden_at is null) then
    perform booking._err('unsupported', 'Varaukseen liittyy lisäpalveluvarauksia; siirrä hallinnan kautta');
  end if;

  -- Kohdesessio: säännön pitää olla aktiivinen ja p_starts_at oikea session alku (sama logiikka kuin svc_move_reservation).
  begin
    select * into rs from booking._resolve_session(p_rule_id, v_date, res.persons, false);
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_code in ('no_session', 'not_bookable', 'product_inactive', 'rule_not_found', 'sale_closed') then
      perform booking._err('slot_invalid', v_msg);
    else
      raise;
    end if;
  end;
  if date_trunc('minute', rs.o_starts_at) <> date_trunc('minute', p_starts_at) then
    perform booking._err('slot_invalid', format('Säännön %s sessio alkaa %s, ei %s', p_rule_id,
      to_char(rs.o_starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
      to_char(p_starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI')));
  end if;
  if exists (select 1 from booking.product_space_rules psr where psr.product_id = rs.o_product_id and psr.active and psr.leg_no > 1)
     or exists (select 1 from booking.product_config pc where pc.product_id = rs.o_product_id and pc.required_skill is not null) then
    perform booking._err('unsupported', 'Kohdetuote vaatii lisäresursseja (legit/saunottaja); siirrä hallinnan kautta');
  end if;
  if rs.o_rule_id = res.rule_id and date_trunc('minute', rs.o_starts_at) = date_trunc('minute', res.starts_at) then
    perform booking._err('no_change', 'Varaus on jo tässä sessiossa');
  end if;

  v_pools := coalesce(rs.o_pool_ids, '{}'::bigint[]);
  v_sess := booking._session_key(v_pools, rs.o_mode, rs.o_starts_at);
  v_total := o.total_gross;
  select md5(coalesce(string_agg(i.id::text || ':' || coalesce(i.product_id::text, '') || ':' || coalesce(i.product_name, '') || ':'
                                 || i.unit_price_gross::text || ':' || i.line_total_gross::text || ':' || coalesce(i.vat_rate::text, '')
                                 || ':' || coalesce(i.line_vat::text, ''), ',' order by i.id), ''))
    into v_price_sig from booking.order_items i where i.order_id = o.id;
  select * into v_item from booking.order_items i where i.id = res.order_item_id;
  select p.name into v_old_prod_name from kb.products p where p.id = res.product_id;
  select p.name into v_new_prod_name from kb.products p where p.id = rs.o_product_id;
  select r.label into v_old_rule_label from booking.schedule_rules r where r.id = res.rule_id;
  select r.label into v_new_rule_label from booking.schedule_rules r where r.id = rs.o_rule_id;
  begin
    select pr.total into v_target_price from booking._rule_price(rs.o_rule_id, res.persons) pr;
  exception when others then v_target_price := null;
  end;

  v_old := jsonb_build_object('product_id', res.product_id, 'product_name', v_old_prod_name, 'rule_id', res.rule_id,
            'rule_label', v_old_rule_label, 'space_id', res.space_id, 'mode', res.mode, 'pool_ids', res.pool_ids,
            'starts_at', res.starts_at, 'ends_at', res.ends_at, 'persons', res.persons);
  v_plan := jsonb_build_object(
    'order_no', o.order_no, 'reservation_id', res.id, 'order_status', o.status, 'payment_status', o.payment_status,
    'old', v_old,
    'new', jsonb_build_object('product_id', rs.o_product_id, 'product_name', v_new_prod_name, 'rule_id', rs.o_rule_id,
            'rule_label', v_new_rule_label, 'space_id', rs.o_space_id, 'mode', rs.o_mode, 'pool_ids', v_pools,
            'starts_at', rs.o_starts_at, 'ends_at', rs.o_ends_at, 'persons', res.persons),
    'order_total_unchanged', v_total,
    'order_item', case when v_item.id is null then null else jsonb_build_object('id', v_item.id, 'product_id', v_item.product_id,
            'product_name', v_item.product_name, 'line_total_gross', v_item.line_total_gross, 'action', 'ennallaan (ei muutosta)') end,
    'target_rule_price_info', v_target_price,
    'no_payment_link', true, 'no_refund', true, 'no_customer_message', true,
    'requested_by', v_req, 'note', v_note, 'actor', v_actor);

  -- Sulku, päällekkäisyys ja poolikapasiteetti kohdesessiolle samalla logiikalla kuin reservations_validate.
  begin
    if booking._rule_closure_exempt(rs.o_rule_id, rs.o_space_id) then
      if res.override_reason is null and exists (
           select 1 from booking.space_blocks b where b.active and b.space_id = rs.o_space_id
              and b.during && tstzrange(rs.o_starts_at, rs.o_ends_at, '[)')
              and b.closure_event_id is null and not booking._event_block_is_own(b.event_block_id, res.id, v_pools)) then
        perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)');
      end if;
    else
      perform booking._check_claim(res.id, null, rs.o_space_id, 'space', rs.o_mode, rs.o_starts_at, rs.o_ends_at, res.persons,
                                   v_pools, null, v_sess, res.quota_exempt, (res.override_reason is not null), 'blocks');
    end if;
    perform booking._check_claim(res.id, null, rs.o_space_id, 'space', rs.o_mode, rs.o_starts_at, rs.o_ends_at, res.persons,
                                 v_pools, null, v_sess, res.quota_exempt, (res.override_reason is not null), 'rest');
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_preview then
      return jsonb_build_object('ok', false, 'preview', true, 'error_code', v_code, 'message', v_msg, 'plan', v_plan);
    end if;
    if v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
      perform booking._err('slot_taken', v_msg);
    end if;
    raise;
  end;

  if v_preview then
    return jsonb_build_object('ok', true, 'preview', true, 'plan', v_plan);
  end if;

  begin
    update booking.reservations set
      product_id = rs.o_product_id,
      rule_id = rs.o_rule_id,
      space_id = rs.o_space_id,
      mode = rs.o_mode,
      starts_at = rs.o_starts_at,
      ends_at = rs.o_ends_at,
      pool_ids = v_pools,
      claim_offset_min = 0,
      claim_minutes = null,
      off_schedule = false,
      off_schedule_by = null
     where id = res.id
    returning * into res;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
      perform booking._err('slot_taken', v_msg);
    end if;
    raise;
  end;

  perform booking._clear_staff_overrides();
  perform set_config('booking.svc_overbook', 'off', true);

  if (select x.total_gross from booking.orders x where x.id = o.id) is distinct from v_total
     or (select md5(coalesce(string_agg(i.id::text || ':' || coalesce(i.product_id::text, '') || ':' || coalesce(i.product_name, '') || ':'
                                 || i.unit_price_gross::text || ':' || i.line_total_gross::text || ':' || coalesce(i.vat_rate::text, '')
                                 || ':' || coalesce(i.line_vat::text, ''), ',' order by i.id), ''))
           from booking.order_items i where i.order_id = o.id) is distinct from v_price_sig then
    perform booking._err('price_changed', 'Siirto olisi muuttanut tilauksen summaa tai rivejä');
  end if;

  v_line := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor
    || ': varaus ' || res.id || ' siirretty ' || coalesce(v_old_prod_name, '?') || ' (sääntö ' || coalesce((v_old->>'rule_id'), '-') || ', '
    || to_char((v_old->>'starts_at')::timestamptz at time zone booking._tz(), 'DD.MM.YYYY HH24:MI') || ') -> '
    || coalesce(v_new_prod_name, '?') || ' (sääntö ' || rs.o_rule_id || ', '
    || to_char(rs.o_starts_at at time zone booking._tz(), 'DD.MM.YYYY HH24:MI') || '–' || to_char(rs.o_ends_at at time zone booking._tz(), 'HH24:MI')
    || '). Hinta ja tilausrivit ennallaan'
    || case when v_item.id is not null then ' (rivi ' || v_item.id || ' "' || coalesce(v_item.product_name, '') || '" jätetty ennalleen)' else '' end
    || '. Pyytäjä: ' || v_req || '. Syy: ' || v_note;
  update booking.orders set internal_note = concat_ws(E'\n', internal_note, v_line) where id = o.id;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'reservations', res.id::text,
          'SVC_MOVE_RESERVATION_TO_RULE',
          v_old || jsonb_build_object('order_no', o.order_no, 'total', v_total),
          jsonb_build_object('order_no', o.order_no, 'product_id', res.product_id, 'rule_id', res.rule_id, 'space_id', res.space_id,
            'mode', res.mode, 'pool_ids', res.pool_ids, 'starts_at', res.starts_at, 'ends_at', res.ends_at, 'persons', res.persons,
            'total', v_total, 'order_item_unchanged', v_item.id, 'requested_by', v_req, 'note', v_note, 'actor', v_actor));

  return jsonb_build_object('ok', true, 'preview', false, 'plan', v_plan,
    'result', jsonb_build_object('product_id', res.product_id, 'rule_id', res.rule_id, 'starts_at', res.starts_at,
      'ends_at', res.ends_at, 'pool_ids', res.pool_ids, 'total', v_total));
end
$function$;

comment on function booking.svc_move_reservation_to_rule(bigint, bigint, bigint, timestamptz, text, text, text, boolean) is
  'booking_294: siirtää varauksen toiseen sääntöön/tuotteeseen; summa, rivit, ALV ja maksut ennallaan; ei maksulinkkiä, hyvitystä eikä asiakasviestiä. Oletus preview.';

revoke all on function booking.svc_move_reservation_to_rule(bigint, bigint, bigint, timestamptz, text, text, text, boolean) from public, anon, authenticated;
grant execute on function booking.svc_move_reservation_to_rule(bigint, bigint, bigint, timestamptz, text, text, text, boolean) to service_role;
