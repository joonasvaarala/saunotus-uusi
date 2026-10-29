-- booking_213: tapahtumakerran myydyt paikat ja kapasiteetti sisältävät Johku-varaukset (t1092u, Joonas 29.10.2026).
--
-- Syy: johku-avaus (28.10.2026) loi tapahtumakerrat 67–72 niin, että kerran max_persons = Johkun VAPAAT paikat
-- ja loppuunmyydyt kerrat merkittiin max 1 / min 2 (julkinen tila "full" vain siksi, että min > jäljellä).
-- Johku-varaukset (external_source='johku', rule_id null) eivät olleet kerran poolissa, joten hallinta näytti
-- 0 / 1 myyty, eikä jonoon voinut liittyä (min 2 > max 1).
--
-- 1) booking._event_rule_res_ids(rule): kerran varaukset = rule_id-liput + saman tuotteen Johku-varaukset, joiden
--    alku on ±30 min kerran alusta (ei piilotettuja). Yksi totuus hallinnan yleiskatsaukselle, osallistujille ja CSV:lle.
-- 2) booking._pool_peak: tapahtumakerran oma pooli (event_rule_<id>) laskee myös kerralle kohdistuvat Johku-varaukset
--    (ellei varaus ole jo poolissa). Johkussa peruttu paikka vapautuu uudessa kaupassa ja jonolle automaattisesti.
-- 3) _event_rule_json: sold_persons sisältää Johku-paikat; uudet kentät johku_persons, johku_count.
--    admin_event_rule_upsert: max_below_sold ja passivointiesto laskevat Johku-paikat; Johku-varauksellisen kerran
--    aikaa ei voi siirtää (Johku-varaukset eivät siirry). admin_event_participants: Johku-osallistujat mukaan
--    (source = 'johku'). admin_event_participant_note_set: muistiinpano myös Johku-osallistujalle.
-- 4) admin_event_message_send: ei automaattista Tapio-allekirjoitusta (t1093u, Joonas: henkilökunta kirjoittaa itse).
--    Johku-tilauksille ei edelleenkään lähetetä viestejä (o.external_source is null).
-- 5) Data: johku-avaus-kerroilla max_persons = Johkun kokonaiskapasiteetti (muistiinpanon "N/M": M), ja max 1 / min 2
--    -kerroilla min_persons = tuotteen min (1). Tehdään vain, jos kerralle kohdistuvat Johku-paikat = N ja
--    nykyinen vapaa määrä = M − N (tai loppuunmyyty-merkintä). Muuten kerta ohitetaan (notice). Tuotannossa:
--    67 Kekri 31.10 8/8, 68 13.11 8/8, 69 4.12 17:00 8/8, 70 4.12 19:00 8/8, 71 18.12 7/8, 72 20.2.2027 3/9.
-- Ei hintojen, ALV:n, kassan eikä Johku-tuonnin muutoksia. Ei sähköposteja (kerroilla ei jonoa).
-- Rollback: ../rollbacks/<versio>_booking_213_ROLLBACK.sql
set local lock_timeout = '5s';

create or replace function booking._event_rule_res_ids(p_rule_id bigint)
returns table(id bigint, external boolean) language sql stable security definer set search_path = '' as $$
  select x.id, false from booking.reservations x where x.rule_id = p_rule_id
  union all
  select x.id, true
    from booking.schedule_rules r
    join booking.reservations x
      on x.external_source = 'johku' and x.rule_id is null and x.hidden_at is null and x.product_id = r.product_id
     and x.starts_at >= ((r.valid_from + r.start_time) at time zone booking._tz()) - interval '30 minutes'
     and x.starts_at <= ((r.valid_from + r.start_time) at time zone booking._tz()) + interval '30 minutes'
   where r.id = p_rule_id and r.kind = 'event' and r.valid_from is not null
$$;
revoke all on function booking._event_rule_res_ids(bigint) from public, anon, authenticated;
grant execute on function booking._event_rule_res_ids(bigint) to service_role;
comment on function booking._event_rule_res_ids(bigint) is
  'booking_213: tapahtumakerran varaukset: rule_id-liput (external=false) ja saman tuotteen Johku-varaukset, alku ±30 min kerran alusta (external=true).';

CREATE OR REPLACE FUNCTION booking._pool_peak(p_pool bigint, p_from timestamp with time zone, p_to timestamp with time zone, p_exclude bigint DEFAULT NULL::bigint)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return (
with rs as materialized (
    select r.starts_at + make_interval(mins => r.claim_offset_min) as s,
           case when r.claim_minutes is null then r.ends_at
                else r.starts_at + make_interval(mins => r.claim_offset_min + r.claim_minutes) end as e,
           r.persons as n
      from booking.reservations r
     where r.mode = 'shared' and r.pool_ids @> array[p_pool]
       and r.status in ('pending', 'confirmed')
       and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at + make_interval(mins => r.claim_offset_min) < p_to
       and case when r.claim_minutes is null then r.ends_at
                else r.starts_at + make_interval(mins => r.claim_offset_min + r.claim_minutes) end > p_from
       and r.id is distinct from p_exclude
    union all
    select l.starts_at as s, l.ends_at as e, l.persons as n
      from booking.reservation_legs l
      join booking.reservations r on r.id = l.reservation_id
     where l.mode = 'shared' and l.pool_ids @> array[p_pool]
       and r.status in ('pending', 'confirmed')
       and booking._res_active(r.status, r.hold_expires_at)
       and l.starts_at < p_to and l.ends_at > p_from
       -- indeksiehto (gist during): least/greatest + '[]' = aina ylijoukko yllä olevasta vertailusta, ei virhettä käänteisillä rajoilla
       and l.during && tstzrange(least(p_from, p_to), greatest(p_from, p_to), '[]')
       and l.reservation_id is distinct from p_exclude
    union all
    -- booking_139: voimassa oleva jonotuspito (vain vuoroon ≥ 48 h annettu, hold_expires_at > now()) varaa pidon henkilömäärän
    -- vuoron ajaksi vuoron kapasiteettipooleista. Ei koske pidon haltijaa itseään eikä henkilökuntaa (_waitlist_hold_counts).
    select w.starts_at as s, w.ends_at as e, w.persons as n
      from booking.waitlist_entries w
      join booking.schedule_rules sr on sr.id = w.rule_id and sr.mode = 'shared'
     where w.status = 'notified' and w.hold_expires_at > now()
       and w.starts_at < p_to and w.ends_at > p_from
       and exists (select 1 from booking.schedule_rule_pools rp where rp.rule_id = w.rule_id and rp.pool_id = p_pool)
       and booking._waitlist_hold_counts(w.id)
    union all
    -- booking_213: tapahtumakerran oma pooli (event_rule_<id>) laskee kerralle kohdistuvat Johku-varaukset koko kerran ajalle.
    select ev.s, ev.e, x.persons as n
      from booking.resources pr
      join booking.schedule_rule_pools rp on rp.pool_id = pr.id
      join booking.schedule_rules sr on sr.id = rp.rule_id and sr.kind = 'event' and pr.code = 'event_rule_' || sr.id::text
      cross join lateral (select (sr.valid_from + sr.start_time) at time zone booking._tz() as s,
                                 (sr.valid_from + sr.start_time + make_interval(mins => sr.duration_minutes)) at time zone booking._tz() as e) ev
      join booking._event_rule_res_ids(sr.id) i on i.external
      join booking.reservations x on x.id = i.id
     where pr.id = p_pool and pr.kind = 'capacity_pool' and pr.code like 'event\_rule\_%'
       and not (x.pool_ids @> array[p_pool])
       and x.status in ('pending', 'confirmed')
       and booking._res_active(x.status, x.hold_expires_at)
       and ev.s < p_to and ev.e > p_from
       and x.id is distinct from p_exclude
  ), base as (
    select coalesce(sum(n), 0) as n from rs where s <= p_from
  ), ev as (
    select e as t, -n as d from rs where e > p_from and e < p_to
    union all
    select s as t, n as d from rs where s > p_from and s < p_to
  ), step as (
    select t, sum(d) as d from ev group by t
  ), run as (
    select (select n from base) + sum(d) over (order by t) as load from step
  )
  select coalesce(greatest((select n from base), (select max(load) from run)), 0)::integer
  );
end
$function$;

create or replace function booking._event_rule_json(p_rule_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'product_id', r.product_id, 'kind', r.kind, 'date', r.valid_from, 'start_time', to_char(r.start_time, 'HH24:MI'),
    'duration_minutes', r.duration_minutes,
    'starts_at', (r.valid_from + r.start_time) at time zone booking._tz(),
    'ends_at', ((r.valid_from + r.start_time) + make_interval(mins => r.duration_minutes)) at time zone booking._tz(),
    'max_persons', r.max_persons, 'min_persons', r.min_persons, 'deadline_minutes', r.deadline_minutes,
    'label', r.label, 'label_en', r.label_en, 'active', r.active, 'cancelled_at', r.cancelled_at,
    'price_variant_id', r.price_variant_id, 'space_id', r.space_id,
    'pool_id', (select pr.id from booking.resources pr where pr.code = 'event_rule_' || r.id::text),
    -- booking_213: myydyt = uuden kaupan liput (rule_id) + kerralle kohdistuvat Johku-varaukset (_event_rule_res_ids).
    'sold_persons', (select coalesce(sum(x.persons), 0)::int from booking._event_rule_res_ids(r.id) i
                      join booking.reservations x on x.id = i.id
                      where booking._res_active(x.status, x.hold_expires_at)),
    'johku_persons', (select coalesce(sum(x.persons), 0)::int from booking._event_rule_res_ids(r.id) i
                      join booking.reservations x on x.id = i.id
                      where i.external and booking._res_active(x.status, x.hold_expires_at)),
    'reservation_count', (select count(*)::int from booking._event_rule_res_ids(r.id) i),
    'johku_count', (select count(*)::int from booking._event_rule_res_ids(r.id) i where i.external),
    'waitlist_count', (select count(*)::int from booking.waitlist_entries w where w.rule_id = r.id and w.status in ('waiting', 'notified')),
    'blocks', coalesce((select jsonb_agg(booking._event_block_json(b) order by b.sort_order, b.id)
                          from booking.event_resource_blocks b where b.rule_id = r.id), '[]'::jsonb))
  from booking.schedule_rules r where r.id = p_rule_id
$$;

create or replace function booking.admin_event_rule_upsert(p_id bigint default null, p_product_id bigint default null, p_patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  allowed text[] := array['date','start_time','duration_minutes','max_persons','min_persons','deadline_minutes','label','label_en','active','price_variant_id'];
  k text; r booking.schedule_rules; p kb.products; pc booking.product_config;
  v_date date; v_start time; v_dur integer; v_max integer; v_min integer; v_deadline integer; v_label text; v_label_en text; v_active boolean;
  v_variant bigint; v_space bigint; v_sold integer; v_ext integer; v_has_res boolean; v_id bigint; v_auto_label boolean := false;
  v_moved integer := 0; v_new_start timestamptz; v_new_end timestamptz;
begin
  perform booking._require_permission('catalog.edit');
  p_patch := coalesce(p_patch, '{}'::jsonb);
  if jsonb_typeof(p_patch) <> 'object' then perform booking._err('invalid_param', 'p_patch puuttuu'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;

  if p_id is not null then
    select * into r from booking.schedule_rules where id = p_id for update;
    if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
    if p_product_id is not null and p_product_id <> r.product_id then perform booking._err('invalid_param', 'Kerta kuuluu toiseen tuotteeseen'); end if;
    p_product_id := r.product_id;
  end if;
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  if p.category not in ('event', 'training') then perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus'); end if;
  select * into pc from booking.product_config where product_id = p.id;
  if not found then perform booking._err('not_found', 'Tuotteen varausasetukset puuttuvat'); end if;

  if p_patch ? 'date' then
    if coalesce(p_patch ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then perform booking._err('invalid_param', 'Päivä muodossa VVVV-KK-PP'); end if;
    begin v_date := (p_patch ->> 'date')::date; exception when others then perform booking._err('invalid_param', 'Virheellinen päivä'); end;
  else v_date := r.valid_from; end if;
  if p_patch ? 'start_time' then
    if coalesce(p_patch ->> 'start_time', '') !~ '^\d{1,2}[:.]\d{2}(:00)?$' then perform booking._err('invalid_param', 'Alkuaika muodossa HH:MM'); end if;
    begin v_start := replace(p_patch ->> 'start_time', '.', ':')::time; exception when others then perform booking._err('invalid_param', 'Virheellinen alkuaika'); end;
  else v_start := r.start_time; end if;
  if v_date is null then perform booking._err('invalid_param', 'Päivä puuttuu'); end if;
  if v_start is null then perform booking._err('invalid_param', 'Alkuaika puuttuu'); end if;
  -- booking_202 (Joonas 29.10.): olemassa olevaa kertaa ei voi siirtää menneisyyteen (uusi alkuhetki <= nyt).
  if p_id is not null and (v_date, v_start) is distinct from (r.valid_from, r.start_time)
     and ((v_date + v_start) at time zone booking._tz()) <= now() then
    perform booking._err('past_move', 'Kertaa ei voi siirtää menneisyyteen');
  end if;

  v_dur := case when p_patch ? 'duration_minutes' then booking._event_jint(p_patch -> 'duration_minutes', 'duration_minutes', 1, 20160)
                else coalesce(r.duration_minutes, pc.duration_minutes, p.duration_minutes) end;
  if v_dur is null then perform booking._err('invalid_param', 'Kesto puuttuu'); end if;
  if v_dur > 1440 and p.category <> 'training' then
    perform booking._err('multi_day_training_only', 'Monipäiväinen kerta (yksi lippu) on sallittu vain koulutuksille');
  end if;
  v_max := case when p_patch ? 'max_persons' then booking._event_jint(p_patch -> 'max_persons', 'max_persons', 1, 1000)
                when p_id is not null then r.max_persons else pc.max_persons end;
  v_min := coalesce(case when p_patch ? 'min_persons' then booking._event_jint(p_patch -> 'min_persons', 'min_persons', 1, 1000) end,
                    r.min_persons, pc.min_persons, 1);
  if v_max is not null and v_min > v_max then perform booking._err('invalid_param', 'Vähimmäismäärä on suurempi kuin enimmäismäärä'); end if;
  v_deadline := coalesce(case when p_patch ? 'deadline_minutes' then booking._event_jint(p_patch -> 'deadline_minutes', 'deadline_minutes', 0, 43200) end,
                         r.deadline_minutes, 0);
  v_active := coalesce(case when p_patch ? 'active' then booking._event_jbool(p_patch -> 'active', 'active') end, r.active, true);
  if p_patch ? 'price_variant_id' then
    v_variant := booking._event_jint(p_patch -> 'price_variant_id', 'price_variant_id', 1, 2000000000);
    if v_variant is not null and not exists (select 1 from kb.product_price_variants v where v.id = v_variant and v.product_id = p.id) then
      perform booking._err('invalid_param', 'Hintavaihtoehto ei kuulu tuotteeseen');
    end if;
  else v_variant := r.price_variant_id; end if;
  if p_patch ? 'label' then v_label := nullif(btrim(coalesce(p_patch ->> 'label', '')), ''); else v_label := r.label; end if;
  if v_label is null
     or (p_id is not null and not (p_patch ? 'label') and r.label = to_char(r.valid_from, 'DD.MM.YYYY') || ' klo ' || to_char(r.start_time, 'HH24.MI')) then
    v_label := to_char(v_date, 'DD.MM.YYYY') || ' klo ' || to_char(v_start, 'HH24.MI');
    v_auto_label := true;
  end if;
  if char_length(v_label) > 200 then perform booking._err('invalid_param', 'Nimi on liian pitkä'); end if;
  if p_patch ? 'label_en' then v_label_en := nullif(btrim(coalesce(p_patch ->> 'label_en', '')), ''); else v_label_en := r.label_en; end if;
  if v_label_en is not null and char_length(v_label_en) > 200 then perform booking._err('invalid_param', 'Englanninkielinen nimi on liian pitkä'); end if;

  if p_id is null then
    select id into v_space from booking.resources where code = 'ei_resurssia';
    if v_space is null then perform booking._err('not_found', 'Resurssia ei_resurssia ei löydy'); end if;
    insert into booking.schedule_rules(product_id, label, label_en, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to,
                                       min_persons, max_persons, price_mode, price_variant_id, deadline_minutes, active, sort_order, kind, notes)
    values (p.id, v_label, v_label_en, 'shared', v_space, array[extract(isodow from v_date)::smallint], v_start, v_dur, v_date, v_date,
            v_min, v_max, 'per_person', v_variant, v_deadline, v_active, 100, 'event', 'booking_158: tapahtumakerta')
    returning id into v_id;
  else
    -- booking_213: myydyt sisältävät kerralle kohdistuvat Johku-varaukset.
    select coalesce(sum(x.persons), 0)::int, count(*) > 0, coalesce(sum(x.persons) filter (where i.external), 0)::int
      into v_sold, v_has_res, v_ext
      from booking._event_rule_res_ids(r.id) i join booking.reservations x on x.id = i.id
     where booking._res_active(x.status, x.hold_expires_at);
    -- Johku-varaukset kohdistuvat kertaan alkuajan perusteella eivätkä siirry tämän mukana.
    if v_ext > 0 and (v_date, v_start) is distinct from (r.valid_from, r.start_time) then
      perform booking._err('has_reservations', 'Kerralla on Johku-varauksia: aikaa ei voi siirtää');
    end if;
    -- booking_202: aikaa saa siirtää. Passivointi ei käy, jos lippuja on (käytä admin_event_occurrence_cancel).
    if v_has_res and r.active and not v_active then
      perform booking._err('has_reservations', 'Kerralla on varauksia: kertaa ei voi passivoida. Peruuta kerta.');
    end if;
    -- Hallinnan ylibuukkaama kerta (booking_192) on yhä muokattavissa; enimmäismäärää ei silti voi laskea alle myydyn.
    if p_patch ? 'max_persons' and coalesce(v_max, pc.max_persons) is not null and coalesce(v_max, pc.max_persons) < v_sold then
      perform booking._err('max_below_sold', format('Enimmäismäärä ei voi olla pienempi kuin myydyt paikat (%s)', v_sold));
    end if;
    update booking.schedule_rules
       set label = v_label, label_en = v_label_en, weekdays = array[extract(isodow from v_date)::smallint], start_time = v_start,
           duration_minutes = v_dur, valid_from = v_date, valid_to = v_date, min_persons = v_min, max_persons = v_max,
           price_variant_id = v_variant, deadline_minutes = v_deadline, active = v_active,
           cancelled_at = case when v_active then null else cancelled_at end
     where id = r.id;
    v_id := r.id;
    if (v_date, v_start, v_dur) is distinct from (r.valid_from, r.start_time, r.duration_minutes) then
      v_new_start := (v_date + v_start) at time zone booking._tz();
      v_new_end := v_new_start + make_interval(mins => v_dur);
      -- Kerran oma pooli: myydyt paikat siirtyvät sellaisenaan. Pooli nostetaan hetkeksi myytyyn määrään, jotta
      -- hallinnan ylibuukkaama kerta siirtyy; _event_rule_pool_sync palauttaa kapasiteetin alla. Uusia paikkoja ei synny.
      update booking.resources set capacity = v_sold - v_ext where code = 'event_rule_' || r.id::text and capacity < v_sold - v_ext and v_sold - v_ext > 0;
      -- Vanhentuneita pitoja ei siirretä (reservations_validate perii ne _expire_holdsilla saman lauseen aikana).
      update booking.reservations x
         set starts_at = v_new_start, ends_at = v_new_end
       where x.rule_id = r.id
         and (booking._res_active(x.status, x.hold_expires_at) or x.status in ('completed', 'no_show'));
      get diagnostics v_moved = row_count;
      update booking.waitlist_entries w
         set starts_at = v_new_start, ends_at = v_new_end, session_date = v_date
       where w.rule_id = r.id and w.status in ('waiting', 'notified');
    end if;
  end if;

  perform booking._event_rule_pool_sync(v_id);
  perform booking._event_sync_blocks(v_id);
  perform booking._event_raise_conflicts(v_id);
  perform booking._texts_register_sources();
  return booking._event_rule_json(v_id) || jsonb_build_object('moved_bookings', v_moved);
end $$;

create or replace function booking.admin_event_participants(p_product_id bigint, p_rule_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cat text;
begin
  perform booking._require_staff();
  select p.category into v_cat from kb.products p where p.id = p_product_id;
  if v_cat is null or v_cat not in ('event', 'training') then perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus'); end if;
  if p_rule_id is not null and not exists (
    select 1 from booking.schedule_rules r where r.id = p_rule_id and r.product_id = p_product_id and r.kind = 'event'
  ) then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'reservation_id', x.id, 'order_id', o.id, 'order_no', o.order_no, 'rule_id', sr.id,
      'source', case when x.external_source = 'johku' then 'johku' else 'shop' end,
      'occurrence_label', sr.label, 'occurrence_label_en', sr.label_en, 'starts_at', x.starts_at,
      'name', c.name, 'email', c.email, 'phone', c.phone, 'persons', x.persons,
      'order_status', o.status, 'payment_status', o.payment_status, 'reservation_status', x.status,
      'booked_at', o.created_at, 'customer_note', nullif(left(coalesce(o.customer_note, ''), 1000), ''),
      'option_label', po.name, 'option_label_en', po.name_en,
      'adults', case when x.participant_breakdown ->> 'adults' ~ '^[0-9]{1,3}$' then (x.participant_breakdown ->> 'adults')::int end,
      'children', case when x.participant_breakdown ->> 'children' ~ '^[0-9]{1,3}$' then (x.participant_breakdown ->> 'children')::int end,
      'staff_note', n.note
    ) order by x.starts_at, c.name, x.id)
    from booking.schedule_rules sr
    cross join lateral booking._event_rule_res_ids(sr.id) i
    join booking.reservations x on x.id = i.id
    join booking.orders o on o.id = x.order_id
    left join booking.customers c on c.id = o.customer_id
    left join booking.product_options po on po.id = x.product_option_id
    left join booking.event_participant_notes n on n.reservation_id = x.id
    where sr.kind = 'event' and sr.product_id = p_product_id
      and (p_rule_id is null or sr.id = p_rule_id)
      and x.status in ('pending', 'confirmed', 'completed', 'no_show', 'cancelled')
      and (x.status <> 'pending' or x.hold_expires_at > now())
  ), '[]'::jsonb);
end $$;

create or replace function booking.admin_event_participant_note_set(p_reservation_id bigint, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_id bigint;
begin
  perform booking._require_staff();
  if p_reservation_id is null then perform booking._err('invalid_param', 'Varaus puuttuu'); end if;
  if not exists (
    select 1 from booking.reservations x
    join booking.schedule_rules r on r.id = x.rule_id and r.kind = 'event'
    where x.id = p_reservation_id
  ) and not exists (
    -- booking_213: kerralle kohdistuva Johku-varaus
    select 1 from booking.reservations x
    join booking.schedule_rules r on r.kind = 'event' and r.product_id = x.product_id
    join lateral booking._event_rule_res_ids(r.id) i on i.id = x.id
    where x.id = p_reservation_id and x.external_source = 'johku'
  ) then perform booking._err('not_found', 'Tapahtumavarausta ei löydy'); end if;
  if v_note is not null and char_length(v_note) > 2000 then perform booking._err('invalid_param', 'Muistiinpano on liian pitkä'); end if;
  if v_note is null then
    delete from booking.event_participant_notes where reservation_id = p_reservation_id;
    return jsonb_build_object('ok', true, 'reservation_id', p_reservation_id, 'note', null);
  end if;
  insert into booking.event_participant_notes(reservation_id, note, updated_by)
  values (p_reservation_id, v_note, auth.uid())
  on conflict (reservation_id) do update
    set note = excluded.note, updated_by = excluded.updated_by, updated_at = now()
  returning id into v_id;
  return jsonb_build_object('ok', true, 'reservation_id', p_reservation_id, 'note', v_note, 'id', v_id);
end $$;

create or replace function booking.admin_event_message_send(
  p_product_id bigint, p_rule_id bigint, p_subject text, p_body text, p_confirm boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_subject text := regexp_replace(btrim(coalesce(p_subject, '')), '\s+', ' ', 'g');
  v_body text := btrim(coalesce(p_body, ''));
  v_name text; v_name_en text; v_cat text;
  v_start timestamptz; v_end timestamptz;
  v_log bigint; v_queued int := 0; v_skipped int := 0; v_n int := 0; v_bad int := 0;
  rec record; v_loc text; v_when text; v_dedupe text; v_ok boolean; v_status text;
begin
  perform booking._require_permission('messages.edit');
  select p.name, p.name_en, p.category into v_name, v_name_en, v_cat from kb.products p where p.id = p_product_id;
  if v_cat is null or v_cat not in ('event', 'training') then perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus'); end if;
  if char_length(v_subject) < 1 then perform booking._err('no_subject', 'Aihe puuttuu'); end if;
  if char_length(v_subject) > 200 then perform booking._err('subject_long', 'Aihe on liian pitkä'); end if;
  if char_length(v_body) < 1 then perform booking._err('no_body', 'Viesti puuttuu'); end if;
  if char_length(v_body) > 4000 then perform booking._err('body_long', 'Viesti on liian pitkä'); end if;
  if booking._event_message_blocked(v_subject) or booking._event_message_blocked(v_body) then
    perform booking._err('provider_name', 'Viestissä ei saa olla maksuvälittäjän nimeä');
  end if;
  if p_rule_id is not null then
    select (sr.valid_from + sr.start_time) at time zone booking._tz(),
           ((sr.valid_from + sr.start_time) + make_interval(mins => sr.duration_minutes)) at time zone booking._tz()
      into v_start, v_end
      from booking.schedule_rules sr
     where sr.id = p_rule_id and sr.product_id = p_product_id and sr.kind = 'event';
    if v_start is null then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  end if;

  select count(*) filter (where c.email is not null and booking._valid_email(c.email)),
         count(*) filter (where c.email is null or not booking._valid_email(c.email))
    into v_n, v_bad
    from (
      select o.id as order_id
        from booking.reservations x
        join booking.schedule_rules sr on sr.id = x.rule_id and sr.kind = 'event' and sr.product_id = p_product_id
        join booking.orders o on o.id = x.order_id
       where (p_rule_id is null or x.rule_id = p_rule_id)
         and (booking._res_active(x.status, x.hold_expires_at) or x.status = 'completed')
         and o.external_source is null
       group by o.id
    ) t
    join booking.orders o on o.id = t.order_id
    left join booking.customers c on c.id = o.customer_id;
  if v_n + v_bad > 500 then perform booking._err('too_many', 'Liian monta vastaanottajaa'); end if;
  if coalesce(p_confirm, false) is not true then
    return jsonb_build_object(
      'ok', true, 'sent', false, 'recipient_count', v_n, 'skipped_count', v_bad,
      'signature', null, 'subject', v_subject,
      'recipients', coalesce((
        select jsonb_agg(jsonb_build_object('name', c.name, 'order_no', o.order_no, 'persons', t.persons) order by c.name, o.id)
          from (
            select o.id as order_id, sum(x.persons)::int as persons
              from booking.reservations x
              join booking.schedule_rules sr on sr.id = x.rule_id and sr.kind = 'event' and sr.product_id = p_product_id
              join booking.orders o on o.id = x.order_id
             where (p_rule_id is null or x.rule_id = p_rule_id)
               and (booking._res_active(x.status, x.hold_expires_at) or x.status = 'completed')
               and o.external_source is null
             group by o.id
          ) t
          join booking.orders o on o.id = t.order_id
          left join booking.customers c on c.id = o.customer_id
         where c.email is not null and booking._valid_email(c.email)
      ), '[]'::jsonb));
  end if;
  if v_n < 1 then perform booking._err('no_recipients', 'Ei vastaanottajia'); end if;
  v_skipped := v_bad;

  insert into booking.event_messages(product_id, rule_id, subject, body, recipient_count, queued_count, skipped_count, created_by)
  values (p_product_id, p_rule_id, v_subject, v_body, v_n, 0, v_skipped, auth.uid())
  returning id into v_log;

  for rec in
    select o.id as order_id, coalesce(o.locale, 'fi') as locale, sum(x.persons)::int as persons
      from booking.reservations x
      join booking.schedule_rules sr on sr.id = x.rule_id and sr.kind = 'event' and sr.product_id = p_product_id
      join booking.orders o on o.id = x.order_id
      left join booking.customers c on c.id = o.customer_id
     where (p_rule_id is null or x.rule_id = p_rule_id)
       and (booking._res_active(x.status, x.hold_expires_at) or x.status = 'completed')
       and o.external_source is null
       and c.email is not null and booking._valid_email(c.email)
     group by o.id, o.locale
  loop
    v_loc := case when rec.locale = 'en' then 'en' else 'fi' end;
    if p_rule_id is null then
      v_when := case when v_loc = 'en' then 'all occurrences' else 'kaikki kerrat' end;
    else
      v_when := to_char(v_start at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI');
    end if;
    v_dedupe := 'event_message:' || v_log::text || ':' || rec.order_id::text;
    v_ok := booking._enqueue_email('event_message', rec.order_id, null, null, v_dedupe, jsonb_strip_nulls(jsonb_build_object(
      'message_id', v_log, 'subject', v_subject, 'body', v_body,
      'event_name', v_name, 'event_name_en', v_name_en, 'when_text', v_when,
      'starts_at', v_start, 'ends_at', v_end)));
    if coalesce(v_ok, false) then
      select e.status into v_status from booking.email_outbox e where e.dedupe_key = v_dedupe;
      if v_status = 'pending' then v_queued := v_queued + 1; else v_skipped := v_skipped + 1; end if;
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;
  update booking.event_messages set queued_count = v_queued, skipped_count = v_skipped where id = v_log;
  return jsonb_build_object('ok', true, 'sent', true, 'id', v_log, 'recipient_count', v_n, 'queued_count', v_queued, 'skipped_count', v_skipped, 'signature', null);
end $$;

-- ---------- data: johku-avaus-kertojen kapasiteetti = Johkun kokonaiskapasiteetti ----------
do $d$
declare r record; v_m int; v_n int; v_johku int; v_shop int; v_min int; v_hack boolean;
begin
  for r in
    select sr.*, pc.min_persons as pc_min
      from booking.schedule_rules sr
      left join booking.product_config pc on pc.product_id = sr.product_id
     where sr.kind = 'event' and sr.notes like 'johku-avaus%' and sr.notes not like '%booking_213:%'
       and sr.valid_from >= current_date
     order by sr.id
  loop
    v_n := (regexp_match(r.notes, '(\d+)/(\d+)'))[1]::int;
    v_m := (regexp_match(r.notes, '(\d+)/(\d+)'))[2]::int;
    select coalesce(sum(x.persons) filter (where i.external), 0)::int, coalesce(sum(x.persons) filter (where not i.external), 0)::int
      into v_johku, v_shop
      from booking._event_rule_res_ids(r.id) i join booking.reservations x on x.id = i.id
     where booking._res_active(x.status, x.hold_expires_at);
    v_hack := r.min_persons > r.max_persons;
    if v_m is null or v_n is null or v_johku <> v_n or v_m < v_johku + v_shop
       or not ((v_hack and v_m = v_n) or (not v_hack and r.max_persons = v_m - v_n)) then
      raise notice 'booking_213: kerta % ohitettu (muistiinpano %/%, Johku %, uusi kauppa %, max %, min %)',
        r.id, v_n, v_m, v_johku, v_shop, r.max_persons, r.min_persons;
      continue;
    end if;
    v_min := case when v_hack then least(greatest(coalesce(r.pc_min, 1), 1), v_m) else r.min_persons end;
    update booking.schedule_rules
       set max_persons = v_m, min_persons = v_min,
           notes = r.notes || format(' | booking_213: max_persons = Johkun kokonaiskapasiteetti %s (ennen %s, min %s), Johku-varaukset lasketaan kerran pooliin', v_m, r.max_persons, r.min_persons)
     where id = r.id;
    raise notice 'booking_213: kerta % max % -> %, min % -> %', r.id, r.max_persons, v_m, r.min_persons, v_min;
  end loop;
end $d$;

comment on function booking._event_rule_json(bigint) is
  'booking_213: tapahtumakerran JSON. sold_persons = uuden kaupan liput + kerralle kohdistuvat Johku-varaukset (johku_persons).';
comment on function booking.admin_event_participants(bigint, bigint) is
  'booking_213: tapahtuman osallistujat (henkilökunta), myös kerralle kohdistuvat Johku-varaukset (source = johku).';
comment on function booking.admin_event_message_send(bigint, bigint, text, text, boolean) is
  'booking_213: esikatselu (p_confirm false) tai lähetys tapahtuman osallistujille (_enqueue_email event_message). messages.edit. Ei automaattista allekirjoitusta (henkilökunta kirjoittaa itse). Ei Johku-tilauksille.';
