-- booking_235: asiakaspalvelu- ja kääntäjäbotin service_role-työkalut.
-- Botti kutsuu näitä service_role-SQL:llä. Ei sähköpostia asiakkaalle, ei maksuriviä, ei hintojen,
-- ALV:n, URL:ien, slugien eikä suomenkielisten tekstien muutosta.
--
-- 1) booking.svc_move_reservation: vahvistetun tilauksen ainoa vahvistettu päävaraus uuteen
--    julkaistuun alkuun samalla tuotteella. Henkilömäärä ja hinta pysyvät.
--    Johku-tuonnin varauksella rule_id on usein NULL (esim. kb 7 Saunarituaali ja savusaunavuoro).
--    Vuoropohjainen tuote: etsitään samaan minuuttiin osuva julkaistu schedule_rules-rivi ja
--    tarkistetaan se booking._resolve_sessionilla (ei booking._change_booking_core, koska se
--    laskee hinnan uudelleen säännöstä ja admin_change_booking vaatii bookings.manage).
--    Aikavälituote (public_slots, kb 7): booking._treatment_slot_check (p_lead false, jotta
--    siirto saa olla tänäänkin kunhan alku on tulevaisuudessa) + booking._plan_legs.
--    Myyntihorisontti: booking_horizon_days, ja aikavälituotteella lisäksi julkinen hoitohorisontti.
--    Sulut (Hoidot kiinni / Rauni kiinni / käsisulku) ja päällekkäisyys tulevat _plan_legs /
--    reservations_validate / _check_claim -polusta. Ei ylibuukkausta eikä aikataulun ohitusta.
--    Legit: vuoropolulla reservations_sync_legs siirtää offsetit; aikavälipolulla legit
--    suunnitellaan uudelleen (_plan_legs), jotta alkuaikapooli (yleinen_vkp_HHMM) vaihtuu.
--    Rituaalilisäpalvelu seuraa olemassa olevaa reservations_ritual_addon_parent-triggeriä
--    (_ritual_addon_move). Muu vahvistettu lapsivaraus siirtyy saman verran. Peruttu sisarus ei.
--    Sisäänkirjattua (checkin_at) ei siirretä. Asiakkaan vahvistusviestiä ei jonoteta
--    (botti lähettää omansa). Vapautunut aika voi yhä herättää olemassa olevan jonotusviestin,
--    sama kuin mikä tahansa varauksen siirto.
--    Vuoropolulla uuden säännön keston pitää olla sama kuin varauksen (duration_differs) ja,
--    jos varauksella on rule_id, säännön hinnan sama (price_differs): hintaa ei lasketa uudelleen.
--    therapist_missing nollautuessa myös therapist_exception_* tyhjennetään (kuten _ritual_addon_move).
--
-- 2) booking.svc_mark_order_paid_external: payment_status = paid ja rivi internal_noteen.
--    Ei payments-riviä, ei viestiä. Olemassa oleva maksetuksi-tulemisen triggeri (lahjakortin
--    aktivointi / vuosikortin myöntäminen) saa laueta, koska se on tilan oma seuraus, mutta jos se
--    jonottaa tämän tilauksen viestin, merkintä perutaan (email_queued; esim. lahjakorttiostos).
--    Vain confirmed/completed-tilaus (not_changeable). Laskutettua tai laskulukittua (booking_185)
--    tilausta ei merkitä (order_invoiced): maksu kirjataan laskulle.
--
-- 3) Kääntäjä: booking.svc_texts_stale_en listaa suomenkieliset site_texts-rivit (myös
--    kb.products-lähteiset), joiden englanti puuttuu tai on vanhempi kuin suomen viimeisin
--    julkaisu. Peilaamaton aktiivisen tuotteen tekstikenttä tulee mukaan, jos site_texts-riviä
--    ei ole. booking.svc_set_product_text_en kirjoittaa vain *_en-kentän
--    (name, description, short_description, duration_text) tekstijärjestelmän julkaisun kautta
--    (_text_validate + _text_publish). Hinta, ALV, slug, URL, active ja suomi eivät muutu.
--    Suomen myöhempi muokkaus nostaa fi.published_at:n, jolloin rivi palaa listalle.
--
-- Rollback: rollbacks/20261102120000_booking_235_ROLLBACK.sql

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function booking.svc_move_reservation(
  p_order_no bigint,
  p_new_start timestamptz,
  p_note text,
  p_actor text default 'asiakaspalvelu-bot'
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  o booking.orders;
  res booking.reservations;
  rs record;
  lp booking.leg_plan;
  v_prim booking.leg_plan;
  v_plan booking.leg_plan[] := '{}';
  v_actor text;
  v_note text;
  v_today date;
  v_date date;
  v_horizon integer;
  v_n integer;
  v_rule bigint;
  v_sched boolean := false;
  v_start timestamptz;
  v_end timestamptz;
  v_old_start timestamptz;
  v_space bigint;
  v_mode text;
  v_pools bigint[];
  v_off integer;
  v_cmin integer;
  v_missing boolean := false;
  v_persons integer;
  v_total numeric;
  v_price_sig text;
  v_code text;
  v_msg text;
  v_ids bigint[];
  v_ss timestamptz[];
  v_es timestamptz[];
  v_i integer;
  v_cur timestamptz;
begin
  perform booking._clear_staff_overrides();
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'asiakaspalvelu-bot');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_today := (now() at time zone booking._tz())::date;
  v_horizon := coalesce((booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int, 120);

  if p_order_no is null then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if v_note is null then
    perform booking._err('note_required', 'Anna syy (p_note)');
  end if;
  if p_new_start is null then
    perform booking._err('invalid_time', 'Anna uusi alkuaika');
  end if;
  if p_new_start <= now() then
    perform booking._err('not_in_future', 'Uuden vuoron pitää alkaa tulevaisuudessa');
  end if;
  v_date := (p_new_start at time zone booking._tz())::date;
  if v_date > v_today + v_horizon then
    perform booking._err('beyond_horizon', format('Uuden vuoron pitää olla enintään %s päivän päässä', v_horizon));
  end if;

  select * into o from booking.orders where order_no = p_order_no for update;
  if not found then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if o.status in ('cancelled', 'expired') then
    perform booking._err('order_cancelled', 'Peruttua tilausta ei voi siirtää');
  end if;
  if o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistetun tilauksen varauksen voi siirtää');
  end if;

  select count(*) into v_n
    from booking.reservations r
   where r.order_id = o.id
     and r.status = 'confirmed'
     and r.parent_reservation_id is null
     and r.hidden_at is null;
  if v_n = 0 then
    perform booking._err('no_reservation', 'Tilauksella ei ole vahvistettua varausta');
  end if;
  if v_n > 1 then
    perform booking._err('ambiguous_reservation', 'Tilauksella on useita vahvistettuja varauksia');
  end if;

  select * into res
    from booking.reservations r
   where r.order_id = o.id
     and r.status = 'confirmed'
     and r.parent_reservation_id is null
     and r.hidden_at is null
   for update;
  if res.checkin_at is not null then
    perform booking._err('already_checked_in', 'Sisäänkirjattua varausta ei voi siirtää');
  end if;
  if res.product_id is null then
    perform booking._err('slot_invalid', 'Varauksella ei ole tuotetta, joten julkaistua vuoroa ei voi ratkaista');
  end if;

  select r.id into v_rule
    from booking.schedule_rules r
    join kb.products p on p.id = r.product_id and p.active
    join booking.product_config pc on pc.product_id = r.product_id
         and pc.bookable and pc.lifecycle = 'current'
   where r.active
     and r.product_id = res.product_id
     and extract(isodow from v_date)::smallint = any (r.weekdays)
     and (r.valid_from is null or v_date >= r.valid_from)
     and (r.valid_to is null or v_date <= r.valid_to)
     and date_trunc('minute', ((v_date + r.start_time) at time zone booking._tz()))
         = date_trunc('minute', p_new_start)
   order by (r.duration_minutes = (extract(epoch from (res.ends_at - res.starts_at)) / 60)::int) desc,
            (r.id is not distinct from res.rule_id) desc, r.sort_order, r.id
   limit 1;

  if v_rule is not null then
    begin
      select * into rs from booking._resolve_session(v_rule, v_date, res.persons, false);
      if rs.o_product_id is distinct from res.product_id then
        perform booking._err('product_mismatch', 'Varauksen voi siirtää vain saman tuotteen vuoroon');
      end if;
      v_sched := true;
      v_start := rs.o_starts_at;
      v_end := rs.o_ends_at;
      v_space := rs.o_space_id;
      v_mode := rs.o_mode;
      v_pools := coalesce(rs.o_pool_ids, '{}'::bigint[]);
      -- Hinta ei muutu siirrossa, joten vuoron kesto ja hinta eivät saa muuttua (esim. 2 h -> 7 h samalla hinnalla).
      if (v_end - v_start) is distinct from (res.ends_at - res.starts_at) then
        perform booking._err('duration_differs', 'Uuden vuoron kesto poikkeaa nykyisestä; siirrä hallinnan kautta');
      end if;
      if res.rule_id is not null and res.rule_id <> v_rule
         and (select pr.total from booking._rule_price(v_rule, res.persons) pr)
             is distinct from (select pr.total from booking._rule_price(res.rule_id, res.persons) pr) then
        perform booking._err('price_differs', 'Uuden vuoron hinta poikkeaa nykyisestä; siirrä hallinnan kautta');
      end if;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
      if v_code = 'no_session' then
        v_rule := null;
      elsif v_code in ('not_bookable', 'product_inactive', 'rule_not_found') then
        perform booking._err('slot_invalid', v_msg);
      else
        raise;
      end if;
    end;
  end if;

  if not v_sched then
    v_rule := null;
    v_start := date_trunc('minute', p_new_start);
    begin
      v_end := booking._treatment_slot_check(res.product_id, v_start, res.persons, false);
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
      if v_code = 'too_far' then
        perform booking._err('beyond_horizon', v_msg);
      elsif v_code in ('bad_slot', 'ritual_start', 'time_window', 'not_offered_day', 'not_bookable', 'invalid_date', 'no_session') then
        perform booking._err('slot_invalid', v_msg);
      else
        raise;
      end if;
    end;
    begin
      for lp in select * from booking._plan_legs(res.product_id, v_start, v_end, res.persons, null, false, res.id) loop
        v_plan := array_append(v_plan, lp);
      end loop;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
      if v_code = 'no_therapist' then
        v_missing := true;
        v_plan := '{}';
        for lp in select * from booking._plan_legs(res.product_id, v_start, v_end, res.persons, null, false, res.id, true) loop
          v_plan := array_append(v_plan, lp);
        end loop;
      elsif v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
        perform booking._err('slot_taken', v_msg);
      elsif v_code = 'not_resourced' then
        perform booking._err('slot_invalid', v_msg);
      else
        raise;
      end if;
    end;
    select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
    if v_prim.resource_id is null then
      perform booking._err('slot_invalid', 'Tuotteelta puuttuu julkaistu tila tälle ajalle');
    end if;
    v_space := v_prim.resource_id;
    v_mode := v_prim.mode;
    v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;
    v_off := (extract(epoch from (v_prim.claim_start - v_start)) / 60)::int;
    v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
    if v_mode = 'exclusive' and (v_off <> 0 or v_cmin is not null) then
      perform booking._err('slot_invalid', 'Yksinoikeusvarauksen aikaikkuna on koko varaus');
    end if;
  end if;

  if v_start <= now() then
    perform booking._err('not_in_future', 'Uuden vuoron pitää alkaa tulevaisuudessa');
  end if;
  if date_trunc('minute', v_start) = date_trunc('minute', res.starts_at) then
    perform booking._err('no_change', 'Varaus on jo tällä alkamisajalla');
  end if;

  if v_sched then
    if exists (
      select 1 from booking.space_blocks b
       where b.active and b.space_id = v_space
         and b.during && tstzrange(v_start, v_end, '[)')
    ) then
      perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)');
    end if;
    if exists (
      select 1
        from booking.reservation_legs l
        join booking.space_blocks b on b.active and b.space_id = l.resource_id
         and b.during && tstzrange(
               v_start + make_interval(mins => l.offset_min),
               case when l.minutes is null then v_end else v_start + make_interval(mins => l.offset_min + l.minutes) end,
               '[)')
       where l.reservation_id = res.id and l.role = 'therapist'
    ) then
      perform booking._err('therapist_closed', 'Saunottajat eivät ole saatavilla tälle ajalle (hoidot kiinni)');
    end if;
  end if;

  v_old_start := res.starts_at;
  v_persons := res.persons;
  v_total := o.total_gross;
  select md5(coalesce(string_agg(i.id::text || ':' || i.unit_price_gross::text || ':' || i.line_total_gross::text, ',' order by i.id), ''))
    into v_price_sig
    from booking.order_items i
   where i.order_id = o.id;
  select coalesce(array_agg(c.id order by c.id), '{}'::bigint[]),
         coalesce(array_agg(c.starts_at order by c.id), '{}'::timestamptz[]),
         coalesce(array_agg(c.ends_at order by c.id), '{}'::timestamptz[])
    into v_ids, v_ss, v_es
    from booking.reservations c
   where c.parent_reservation_id = res.id
     and c.status in ('pending', 'confirmed')
     and c.hidden_at is null;

  if not v_sched then
    delete from booking.reservation_legs where reservation_id = res.id;
  end if;

  begin
    update booking.reservations set
      rule_id = v_rule,
      space_id = v_space,
      mode = v_mode,
      starts_at = v_start,
      ends_at = v_end,
      pool_ids = v_pools,
      claim_offset_min = case when v_sched then claim_offset_min else v_off end,
      claim_minutes = case when v_sched then claim_minutes else v_cmin end,
      therapist_missing = case when v_sched then therapist_missing else v_missing end,
      therapist_exception_at = case when v_sched or v_missing then therapist_exception_at end,
      therapist_exception_by = case when v_sched or v_missing then therapist_exception_by end,
      therapist_exception_note = case when v_sched or v_missing then therapist_exception_note end,
      off_schedule = false,
      off_schedule_by = null,
      overbooked = false,
      overbooked_by = null,
      override_reason = null
     where id = res.id
    returning * into res;

    if not v_sched then
      for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
        insert into booking.reservation_legs(
          reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons,
          pool_ids, skill, session_key, quota_exempt, rule_id)
        values (
          res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
          case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end,
          lp.skill, lp.session_key, res.quota_exempt, lp.rule_id);
      end loop;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
      perform booking._err('slot_taken', v_msg);
    else
      raise;
    end if;
  end;

  if v_ids is not null then
    for v_i in 1 .. cardinality(v_ids) loop
      select c.starts_at into v_cur from booking.reservations c where c.id = v_ids[v_i];
      if v_cur is not distinct from v_ss[v_i] then
        update booking.reservations
           set starts_at = v_ss[v_i] + (v_start - v_old_start),
               ends_at = v_es[v_i] + (v_start - v_old_start)
         where id = v_ids[v_i]
           and status in ('pending', 'confirmed')
           and hidden_at is null;
      end if;
    end loop;
  end if;

  if (select x.persons from booking.reservations x where x.id = res.id) is distinct from v_persons
     or (select x.total_gross from booking.orders x where x.id = o.id) is distinct from v_total
     or (select md5(coalesce(string_agg(i.id::text || ':' || i.unit_price_gross::text || ':' || i.line_total_gross::text, ',' order by i.id), ''))
           from booking.order_items i where i.order_id = o.id) is distinct from v_price_sig then
    perform booking._err('price_changed', 'Siirto olisi muuttanut hintaa tai henkilömäärää');
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (
    auth.uid(),
    coalesce(booking._jwt_role(), 'service_role'),
    'reservations',
    res.id::text,
    'SVC_MOVE_RESERVATION',
    jsonb_build_object('order_no', o.order_no, 'starts_at', v_old_start, 'persons', v_persons, 'total', v_total),
    jsonb_build_object(
      'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at,
      'persons', res.persons, 'total', v_total, 'rule_id', res.rule_id,
      'note', v_note, 'actor', v_actor)
  );

  return jsonb_build_object(
    'ok', true,
    'order_no', o.order_no,
    'old_starts_at', v_old_start,
    'new_starts_at', res.starts_at,
    'ends_at', res.ends_at,
    'persons', res.persons,
    'total', v_total
  );
end
$fn$;

create or replace function booking.svc_mark_order_paid_external(
  p_order_no bigint,
  p_note text,
  p_actor text default 'asiakaspalvelu-bot'
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  o booking.orders;
  v_actor text;
  v_note text;
  v_line text;
  v_pay_n integer;
  v_mail_n integer;
  v_status text;
begin
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'asiakaspalvelu-bot');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if p_order_no is null then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if v_note is null then
    perform booking._err('note_required', 'Anna syy (p_note)');
  end if;

  select * into o from booking.orders where order_no = p_order_no for update;
  if not found then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if o.status in ('cancelled', 'expired') then
    perform booking._err('order_cancelled', 'Peruttua tilausta ei merkitä maksetuksi');
  end if;
  if o.payment_status in ('paid', 'refunded', 'partially_refunded') then
    perform booking._err('already_paid', 'Tilaus on jo maksettu tai hyvitetty');
  end if;
  if o.status not in ('confirmed', 'completed') then
    perform booking._err('not_changeable', 'Vain vahvistetun tilauksen voi merkitä maksetuksi');
  end if;
  if o.payment_status = 'invoiced' or booking._order_invoice_locked(o.id) then
    perform booking._err('order_invoiced', 'Laskutettua tilausta ei merkitä maksetuksi; maksu kirjataan laskulle');
  end if;

  select count(*) into v_pay_n from booking.payments where order_id = o.id;
  select count(*) into v_mail_n from booking.email_outbox where order_id = o.id;
  v_line := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor || ': ' || v_note;
  update booking.orders
     set payment_status = 'paid',
         internal_note = concat_ws(E'\n', internal_note, v_line)
   where id = o.id
  returning payment_status into v_status;

  if (select count(*) from booking.payments where order_id = o.id) is distinct from v_pay_n then
    perform booking._err('payment_row', 'Ulkoista maksua ei kirjata maksujen tauluun');
  end if;
  if (select count(*) from booking.email_outbox where order_id = o.id) is distinct from v_mail_n then
    perform booking._err('email_queued', 'Maksun merkintä ei lähetä asiakkaalle viestiä');
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (
    auth.uid(),
    coalesce(booking._jwt_role(), 'service_role'),
    'orders',
    o.id::text,
    'SVC_MARK_ORDER_PAID_EXTERNAL',
    jsonb_build_object('order_no', o.order_no, 'payment_status', o.payment_status),
    jsonb_build_object('order_no', o.order_no, 'payment_status', v_status, 'note', v_note, 'actor', v_actor)
  );

  return jsonb_build_object(
    'ok', true,
    'order_no', o.order_no,
    'payment_status', v_status
  );
end
$fn$;

create or replace function booking.svc_texts_stale_en(p_limit integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  v_lim integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_total integer;
  v_items jsonb;
begin
  with fi as (
    select t.key, t.source_table, t.source_pk, t.source_column, t.published_text, t.published_at,
           t.published_version, t.max_len, t.placeholders
      from booking.site_texts t
     where t.lang = 'fi'
       and t.class <> 'locked'
       and btrim(t.published_text) <> ''
  ), paired as (
    select fi.key,
           coalesce(fi.source_table, 'site_texts') as source_table,
           fi.source_pk,
           fi.source_column,
           fi.published_text as fi_text,
           coalesce(en.published_text, '') as en_text,
           fi.max_len,
           fi.placeholders,
           fi.published_at as fi_at,
           en.published_at as en_at,
           case
             when en.id is null or btrim(coalesce(en.published_text, '')) = '' or coalesce(en.published_version, 0) = 0 then 'missing'
             when en.published_at is null or fi.published_at is null or en.published_at < fi.published_at then 'older'
             else null
           end as reason
      from fi
      left join booking.site_texts en on en.key = fi.key and en.lang = 'en'
  ), extra as (
    select 'product.' || p.id::text || '.' || f.field as key,
           'kb.products'::text as source_table,
           p.id::text as source_pk,
           f.fi_col as source_column,
           f.fi_text,
           coalesce(f.en_text, '') as en_text,
           f.max_len,
           '{}'::text[] as placeholders,
           null::timestamptz as fi_at,
           null::timestamptz as en_at,
           'unmirrored'::text as reason
      from kb.products p
      cross join lateral (
        values
          ('name'::text, 'name'::text, p.name, p.name_en, 200),
          ('description', 'description', p.description, p.description_en, 8000),
          ('short_description', 'short_description', p.short_description, p.short_description_en, 1000),
          ('duration_text', 'duration_text', p.duration_text, p.duration_text_en, 200)
      ) as f(field, fi_col, fi_text, en_text, max_len)
     where p.active
       and btrim(coalesce(f.fi_text, '')) <> ''
       and not exists (
         select 1 from booking.site_texts t
          where t.source_table = 'kb.products'
            and t.source_pk = p.id::text
            and t.source_column = f.fi_col
            and t.lang = 'fi')
  ), all_rows as (
    select key, source_table, source_pk, source_column, fi_text, en_text, max_len, placeholders, fi_at, en_at, reason
      from paired
     where reason is not null
    union all
    select key, source_table, source_pk, source_column, fi_text, en_text, max_len, placeholders, fi_at, en_at, reason
      from extra
  )
  select count(*) into v_total from all_rows;

  with fi as (
    select t.key, t.source_table, t.source_pk, t.source_column, t.published_text, t.published_at,
           t.published_version, t.max_len, t.placeholders
      from booking.site_texts t
     where t.lang = 'fi'
       and t.class <> 'locked'
       and btrim(t.published_text) <> ''
  ), paired as (
    select fi.key,
           coalesce(fi.source_table, 'site_texts') as source_table,
           fi.source_pk,
           fi.source_column,
           fi.published_text as fi_text,
           coalesce(en.published_text, '') as en_text,
           fi.max_len,
           fi.placeholders,
           fi.published_at as fi_at,
           en.published_at as en_at,
           case
             when en.id is null or btrim(coalesce(en.published_text, '')) = '' or coalesce(en.published_version, 0) = 0 then 'missing'
             when en.published_at is null or fi.published_at is null or en.published_at < fi.published_at then 'older'
             else null
           end as reason
      from fi
      left join booking.site_texts en on en.key = fi.key and en.lang = 'en'
  ), extra as (
    select 'product.' || p.id::text || '.' || f.field as key,
           'kb.products'::text as source_table,
           p.id::text as source_pk,
           f.fi_col as source_column,
           f.fi_text,
           coalesce(f.en_text, '') as en_text,
           f.max_len,
           '{}'::text[] as placeholders,
           null::timestamptz as fi_at,
           null::timestamptz as en_at,
           'unmirrored'::text as reason
      from kb.products p
      cross join lateral (
        values
          ('name'::text, 'name'::text, p.name, p.name_en, 200),
          ('description', 'description', p.description, p.description_en, 8000),
          ('short_description', 'short_description', p.short_description, p.short_description_en, 1000),
          ('duration_text', 'duration_text', p.duration_text, p.duration_text_en, 200)
      ) as f(field, fi_col, fi_text, en_text, max_len)
     where p.active
       and btrim(coalesce(f.fi_text, '')) <> ''
       and not exists (
         select 1 from booking.site_texts t
          where t.source_table = 'kb.products'
            and t.source_pk = p.id::text
            and t.source_column = f.fi_col
            and t.lang = 'fi')
  ), all_rows as (
    select key, source_table, source_pk, source_column, fi_text, en_text, max_len, placeholders, fi_at, en_at, reason
      from paired
     where reason is not null
    union all
    select key, source_table, source_pk, source_column, fi_text, en_text, max_len, placeholders, fi_at, en_at, reason
      from extra
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', q.key,
           'source', case
             when q.source_table = 'site_texts' then 'site_texts'
             else q.source_table || ':' || coalesce(q.source_pk, '') || ':' || coalesce(q.source_column, '')
           end,
           'source_table', q.source_table,
           'source_pk', q.source_pk,
           'source_column', q.source_column,
           'fi', q.fi_text,
           'en', q.en_text,
           'max_len', q.max_len,
           'placeholders', to_jsonb(q.placeholders),
           'reason', q.reason,
           'fi_published_at', q.fi_at,
           'en_published_at', q.en_at
         ) order by q.ord, q.key), '[]'::jsonb)
    into v_items
    from (
      select a.*,
             case a.reason when 'missing' then 0 when 'unmirrored' then 1 else 2 end as ord
        from all_rows a
       order by case a.reason when 'missing' then 0 when 'unmirrored' then 1 else 2 end,
                a.fi_at nulls first, a.key
       limit v_lim
    ) q;

  return jsonb_build_object(
    'ok', true,
    'total', v_total,
    'limit', v_lim,
    'items', v_items
  );
end
$fn$;

create or replace function booking.svc_set_product_text_en(
  p_product_id bigint,
  p_field text,
  p_text text,
  p_actor text default 'kaantaja-bot'
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  p kb.products;
  t booking.site_texts;
  fi booking.site_texts;
  v_actor text;
  v_field text;
  v_col text;
  v_fi text;
  v_price numeric;
  v_vat numeric;
  v_slug text;
  v_url text;
  v_active boolean;
  v_name text;
  v_desc text;
  v_short text;
  v_dur text;
  v_price_text text;
  v_esc text[];
  v_ver integer;
  v_id bigint;
  v_fresh boolean;
begin
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'kaantaja-bot');
  v_field := lower(btrim(coalesce(p_field, '')));
  if v_field ~ '_en$' then
    v_field := regexp_replace(v_field, '_en$', '');
  end if;
  if v_field not in ('name', 'description', 'short_description', 'duration_text') then
    perform booking._err('invalid_field', 'Vain englanninkielinen tuotekenttä: name, description, short_description tai duration_text');
  end if;
  v_col := v_field || '_en';
  if p_product_id is null then
    perform booking._err('not_found', 'Tuotetta ei löydy');
  end if;

  select * into p from kb.products where id = p_product_id for update;
  if not found then
    perform booking._err('not_found', 'Tuotetta ei löydy');
  end if;
  v_price := p.price;
  v_vat := p.vat_rate;
  v_slug := p.slug;
  v_url := p.booking_url;
  v_active := p.active;
  v_name := p.name;
  v_desc := p.description;
  v_short := p.short_description;
  v_dur := p.duration_text;
  v_price_text := p.price_text;

  select * into t
    from booking.site_texts s
   where s.source_table = 'kb.products'
     and s.source_pk = p_product_id::text
     and s.source_column = v_col
     and s.lang = 'en'
   for update;
  if not found then
    perform booking._texts_register_sources();
    select * into t
      from booking.site_texts s
     where s.source_table = 'kb.products'
       and s.source_pk = p_product_id::text
       and s.source_column = v_col
       and s.lang = 'en'
     for update;
  end if;
  if not found then
    perform booking._err('not_found', 'Tuotteen englanninkielistä tekstikenttää ei ole rekisteröity');
  end if;
  if t.class = 'locked' or t.source_column is distinct from v_col then
    perform booking._err('text_locked', 'Tätä kenttää ei voi muuttaa (hinnat, ALV, URL:t ja suomi ovat lukossa)');
  end if;

  perform booking._text_validate(t.class, t.kind, t.max_len, t.placeholders, p_text);
  select * into fi from booking.site_texts s where s.key = t.key and s.lang = 'fi';
  v_fi := coalesce(fi.published_text, '');
  v_fresh := t.published_at is not null and fi.published_at is not null and t.published_at >= fi.published_at
             and btrim(t.published_text) <> '';
  if p_text is not distinct from t.published_text and v_fresh then
    perform booking._err('no_change', 'Teksti ei eroa julkaistusta');
  end if;
  if p_text is distinct from t.published_text then
    v_esc := booking._text_escalation(v_fi, p_text);
    if v_esc && array['link', 'currency', 'email', 'phone'] then
      perform booking._err('facts_changed', 'Englanninkielinen teksti ei saa muuttaa linkkejä, hintoja, puhelinnumeroita tai sähköposteja');
    end if;
  else
    v_esc := '{}';
  end if;

  select coalesce(max(version), 0) + 1 into v_ver from booking.site_text_versions where text_id = t.id;
  insert into booking.site_text_versions(
    text_id, version, text, status, base_version, author, author_kind, author_label, reason,
    escalation, protected, approved_by, approved_by_kind, approved_at)
  values (
    t.id, v_ver, p_text, 'approved', t.published_version, auth.uid(), 'bot', v_actor,
    'Kääntäjä: englanninkielinen tuotekenttä',
    coalesce(v_esc, '{}'),
    t.class = 'protected' or cardinality(coalesce(v_esc, '{}')) > 0,
    auth.uid(), 'bot', now())
  returning id into v_id;
  perform booking._text_publish(v_id);

  select * into p from kb.products where id = p_product_id;
  if p.price is distinct from v_price or p.vat_rate is distinct from v_vat or p.slug is distinct from v_slug
     or p.booking_url is distinct from v_url or p.active is distinct from v_active
     or p.name is distinct from v_name or p.description is distinct from v_desc
     or p.short_description is distinct from v_short or p.duration_text is distinct from v_dur
     or p.price_text is distinct from v_price_text
     or (to_jsonb(p) ->> v_col) is distinct from p_text then
    perform booking._err('forbidden_change', 'Vain englanninkielinen tekstikenttä saa muuttua');
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (
    auth.uid(),
    coalesce(booking._jwt_role(), 'service_role'),
    'kb.products',
    p_product_id::text,
    'SVC_SET_PRODUCT_TEXT_EN',
    jsonb_build_object('field', v_field, 'column', v_col, 'text', t.published_text),
    jsonb_build_object('field', v_field, 'column', v_col, 'key', t.key, 'text', p_text, 'actor', v_actor)
  );

  return jsonb_build_object(
    'ok', true,
    'product_id', p_product_id,
    'field', v_field,
    'key', t.key,
    'text', p_text
  );
end
$fn$;

revoke all on function booking.svc_move_reservation(bigint, timestamptz, text, text) from public, anon, authenticated;
grant execute on function booking.svc_move_reservation(bigint, timestamptz, text, text) to service_role;

revoke all on function booking.svc_mark_order_paid_external(bigint, text, text) from public, anon, authenticated;
grant execute on function booking.svc_mark_order_paid_external(bigint, text, text) to service_role;

revoke all on function booking.svc_texts_stale_en(integer) from public, anon, authenticated;
grant execute on function booking.svc_texts_stale_en(integer) to service_role;

revoke all on function booking.svc_set_product_text_en(bigint, text, text, text) from public, anon, authenticated;
grant execute on function booking.svc_set_product_text_en(bigint, text, text, text) to service_role;

comment on function booking.svc_move_reservation(bigint, timestamptz, text, text) is
  'booking_235: service_role siirtää vahvistetun tilauksen ainoan vahvistetun päävarauksen julkaistuun alkuun. Hinta ja henkilöt ennallaan. Johku (rule_id NULL) kelpaa. Ei asiakasviestiä. Audit SVC_MOVE_RESERVATION.';

comment on function booking.svc_mark_order_paid_external(bigint, text, text) is
  'booking_235: service_role merkitsee tilauksen maksetuksi ulkoisen maksun perusteella (payment_status paid + internal_note). Ei payments-riviä, ei viestiä. Audit SVC_MARK_ORDER_PAID_EXTERNAL.';

comment on function booking.svc_texts_stale_en(integer) is
  'booking_235: service_role listaa suomen tekstit, joiden englanti puuttuu tai on vanhempi kuin suomen viimeisin julkaisu. Mukana tuotteen site_texts-rivit ja peilaamattomat kb.products-kentät.';

comment on function booking.svc_set_product_text_en(bigint, text, text, text) is
  'booking_235: service_role kirjoittaa vain tuotteen *_en-tekstin (name, description, short_description, duration_text). Ei hintaa, ALV:tä, URLia, slugia, active-lippua eikä suomea. Audit SVC_SET_PRODUCT_TEXT_EN.';
