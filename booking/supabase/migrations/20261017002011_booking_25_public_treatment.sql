-- ===================================================================================================================
-- booking_25_public_treatment (17.10.2026): julkinen hoito-/saunotusvaraus (aikaväli- eli legipohjainen "slots"-polku). Additiivinen.
-- Tuotteet: kb 10 Saunahoito, kb 11 Saunotus, kb 12 Syväsaunotus, kb 8 Saunotusrituaali. Tuotteet PIDETÄÄN PIILOSSA (bookable/shop_visible = false) kunnes Joonas erikseen sallii:
--   kaikki julkiset funktiot vaativat product_config.public_slots AND bookable AND shop_visible AND lifecycle='current' -> tuotannossa inertit.
-- Säännöt (Joonas 17.10.):
--  * tarjolla julkisten savusaunavuorojen (schedule_rules: shared, savusauna) päivinä, ei perjantaisin (ei julkisia vuoroja), ei jos päivä suljettu
--  * booking_23-aikaikkuna (therapy: ma–pe alku >= 16:00, la–su >= 13:00, loppu <= 20:30; ritual: alku 16:00/16:30/17:00)
--  * saunottaja ei pakollinen: ei vapaata saunottajaa -> varaus syntyy silti (therapist_missing, booking_22) JOS päivää ei ole suljettu (hoidot kiinni -> therapist_closed estää)
--  * ilmoitus Työvuoro-Tapiolle: booking.notifications_outbox (topic therapist_missing) + notifications_pull/ack (service_role) + therapist_missing_digest()
--  * maksu: pay_later (vahvistettu heti, maksamaton), ei verkkomaksua; token palautetaan
--  * muutos itse viimeistään 48 h ennen (public_change_treatment_booking), ei itseperuutusta, can_change=false jos ei tuettu
-- ===================================================================================================================
set local search_path = booking, extensions, public;

-- ---------- konfiguraatio (additiivinen) ----------
alter table booking.product_config add column if not exists public_slots boolean not null default false;
alter table booking.product_config add column if not exists public_weekdays smallint[];
comment on column booking.product_config.public_slots is 'booking_25: tuote varataan julkisesti aikaväli-polulla (public_treatment_*). Näkyvyys vaatii lisäksi bookable + shop_visible.';
comment on column booking.product_config.public_weekdays is 'booking_25: rajaa julkisen tarjonnan viikonpäiviin (isodow 1-7); null = kaikki julkisten vuorojen päivät.';
update booking.product_config set public_slots = true where product_id in (8, 10, 11, 12);
-- kb 8 (rituaali): sama viikonpäiväsääntö kuin paketilla kb 7 ("la & su"); aika-säännöt (16:00/16:30/17:00) tulevat time_window_rules-taulusta. Laajennus: update ... set public_weekdays = null.
update booking.product_config set public_weekdays = array[6, 7]::smallint[] where product_id = 8;

insert into booking.settings(key, value, description, is_public) values
  ('public_treatment_horizon_days',      '14'::jsonb,  'Julkisten hoitoaikojen ostoikkuna päivinä', false),
  ('public_treatment_min_lead_minutes',  '120'::jsonb, 'Aikaisin varaus: minuuttia ennen alkua', false),
  ('public_treatment_global_per_hour',   '30'::jsonb,  'Suojakatko: uusia julkisia hoitovarauksia / tunti yhteensä', false),
  ('public_treatment_max_open_per_email','5'::jsonb,   'Samalla sähköpostilla tulevia maksamattomia hoitovarauksia enintään', false),
  ('rl_avail_per_10min',                 '60'::jsonb,  'Hoitoaikojen saatavuuskyselyt / IP / 10 min', false)
on conflict (key) do nothing;

-- ---------- ilmoitusjono (Työvuoro-Tapio lukee; ei sähköposteja) ----------
create table if not exists booking.notifications_outbox (
  id          bigint generated always as identity primary key,
  topic       text not null,                                  -- 'therapist_missing'
  target      text not null default 'tapio',
  ref_table   text not null default 'reservations',
  ref_id      bigint not null,
  dedupe_key  text not null,
  payload     jsonb not null default '{}'::jsonb,             -- ei henkilötietoja: varaus-id, tilausnro, tuote, aika, henkilömäärä, päiviä alkuun, lähde
  status      text not null default 'new' check (status in ('new', 'acked', 'resolved')),
  created_at  timestamptz not null default now(),
  acked_at    timestamptz,
  acked_by    text,
  resolved_at timestamptz,
  resolved_reason text,
  constraint notifications_outbox_dedupe unique (dedupe_key)
);
create index if not exists notifications_outbox_pull_idx on booking.notifications_outbox (target, status, created_at);
alter table booking.notifications_outbox enable row level security;
do $$ begin
  if not exists (select 1 from pg_policy where polrelid = 'booking.notifications_outbox'::regclass and polname = 'staff_read') then
    create policy staff_read on booking.notifications_outbox for select to authenticated using ((select booking.is_staff()));
  end if;
end $$;
revoke all on booking.notifications_outbox from public, anon, authenticated;
grant select on booking.notifications_outbox to authenticated;
grant all on booking.notifications_outbox to service_role;

create or replace function booking._therapist_missing_payload(r booking.reservations) returns jsonb
  language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('reservation_id', r.id, 'order_no', o.order_no, 'product_id', r.product_id, 'product_name', coalesce(p.name, ''),
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'source', coalesce(r.external_source, 'native'), 'channel', o.source_channel,
           'days_to_start', ((r.starts_at at time zone 'Europe/Helsinki')::date - (now() at time zone 'Europe/Helsinki')::date))
    from booking.orders o left join kb.products p on p.id = r.product_id where o.id = r.order_id $$;

create or replace function booking.reservations_notify_trg() returns trigger
  language plpgsql security definer set search_path to '' as $function$
begin
  if tg_op = 'INSERT' then
    if new.therapist_missing and new.external_source is null and booking._res_active(new.status, new.hold_expires_at) then
      insert into booking.notifications_outbox(topic, ref_id, dedupe_key, payload)
      values ('therapist_missing', new.id, 'tm:' || new.id::text, booking._therapist_missing_payload(new))
      on conflict (dedupe_key) do nothing;
    end if;
    return null;
  end if;
  -- UPDATE
  if (not new.therapist_missing) or new.therapist_exception_at is not null or not booking._res_active(new.status, new.hold_expires_at) then
    update booking.notifications_outbox set status = 'resolved', resolved_at = now(),
           resolved_reason = case when not new.therapist_missing then 'therapist_assigned' when new.therapist_exception_at is not null then 'exception_granted' else 'reservation_inactive' end
     where topic = 'therapist_missing' and ref_id = new.id and status <> 'resolved';
  elsif new.external_source is null then
    insert into booking.notifications_outbox(topic, ref_id, dedupe_key, payload)
    values ('therapist_missing', new.id, 'tm:' || new.id::text, booking._therapist_missing_payload(new))
    on conflict (dedupe_key) do update
      set payload = excluded.payload,
          status = case when booking.notifications_outbox.status = 'resolved' then 'new' else booking.notifications_outbox.status end,
          resolved_at = case when booking.notifications_outbox.status = 'resolved' then null else booking.notifications_outbox.resolved_at end,
          resolved_reason = case when booking.notifications_outbox.status = 'resolved' then null else booking.notifications_outbox.resolved_reason end;
  end if;
  return null;
end $function$;
drop trigger if exists reservations_notify_ins on booking.reservations;
create trigger reservations_notify_ins after insert on booking.reservations
  for each row when (new.therapist_missing) execute function booking.reservations_notify_trg();
drop trigger if exists reservations_notify_upd on booking.reservations;
create trigger reservations_notify_upd after update of therapist_missing, status, therapist_exception_at, starts_at, ends_at, persons, hold_expires_at on booking.reservations
  for each row when (new.therapist_missing is not null and (old.therapist_missing or new.therapist_missing)) execute function booking.reservations_notify_trg();

create or replace function booking.notifications_pull(p_target text default 'tapio', p_status text default 'new', p_limit integer default 50) returns jsonb
  language plpgsql stable security definer set search_path to '' as $function$
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  return jsonb_build_object('generated_at', now(), 'target', p_target, 'status', p_status,
    'count', (select count(*) from booking.notifications_outbox n where n.target = p_target and n.status = p_status),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'topic', x.topic, 'status', x.status, 'created_at', x.created_at, 'acked_at', x.acked_at, 'payload', x.payload) order by x.created_at)
                         from (select * from booking.notifications_outbox n where n.target = p_target and n.status = p_status order by n.created_at limit greatest(1, least(coalesce(p_limit, 50), 500))) x), '[]'::jsonb));
end $function$;

create or replace function booking.notifications_ack(p_ids bigint[], p_actor text default 'tapio') returns integer
  language plpgsql security definer set search_path to '' as $function$
declare v_n integer;
begin
  if booking._jwt_role() is distinct from 'service_role' and current_user not in ('postgres', 'service_role') then
    perform booking._err('forbidden', 'Vain service_role');
  end if;
  with u as (update booking.notifications_outbox set status = 'acked', acked_at = now(), acked_by = left(coalesce(p_actor, 'tapio'), 60)
              where id = any (coalesce(p_ids, '{}')) and status = 'new' returning 1)
  select count(*) into v_n from u;
  return v_n;
end $function$;

-- ---------- apufunktiot ----------
-- Onko päivä "julkisten saunavuorojen päivä" eikä suljettu: vähintään yksi julkinen (shared, savusauna) sääntövuoro jota savusauna-sulku ei peitä
create or replace function booking._public_shift_day_open(p_date date) returns boolean
  language sql stable security definer set search_path to '' as $$
  select exists (
    select 1 from booking.schedule_rules r join kb.products p on p.id = r.product_id and p.active
     where r.active and r.mode = 'shared' and r.space_id = (select id from booking.resources where code = 'savusauna')
       and extract(isodow from p_date)::smallint = any (r.weekdays)
       and (r.valid_from is null or p_date >= r.valid_from) and (r.valid_to is null or p_date <= r.valid_to)
       and not exists (select 1 from booking.space_blocks b where b.active and b.space_id = r.space_id
                        and b.during && tstzrange((p_date + r.start_time) at time zone booking._tz(), (p_date + r.start_time + make_interval(mins => r.duration_minutes)) at time zone booking._tz(), '[)'))) $$;

-- booking_23-aikaikkunan rikkomus (sama logiikka kuin trigger reservations_time_window): null = ok, muuten 'time_window' | 'ritual_start'
create or replace function booking._time_window_violation(p_product bigint, p_start timestamptz, p_end timestamptz) returns text
  language plpgsql stable security definer set search_path to '' as $function$
declare v_class text; w booking.time_window_rules; ls timestamp; le timestamp; v_dt text;
begin
  select pc.time_window_class into v_class from booking.product_config pc where pc.product_id = p_product;
  if v_class is null then return null; end if;
  ls := p_start at time zone booking._tz(); le := p_end at time zone booking._tz();
  v_dt := case when extract(isodow from ls) >= 6 then 'weekend' else 'weekday' end;
  select * into w from booking.time_window_rules where class = v_class and day_type = v_dt;
  if not found then return null; end if;
  if w.allowed_starts is not null and not (date_trunc('minute', ls)::time = any (w.allowed_starts)) then return 'ritual_start'; end if;
  if w.earliest_start is not null and ls::time < w.earliest_start or w.latest_end is not null and (le::time > w.latest_end or le::date <> ls::date) then return 'time_window'; end if;
  return null;
end $function$;

create or replace function booking._treatment_max_persons(p_product bigint) returns integer
  language sql stable security definer set search_path to '' as $$
  select least(coalesce(pc.max_persons, 1000), coalesce(p.capacity_max, 1000)) from booking.product_config pc join kb.products p on p.id = pc.product_id where pc.product_id = p_product $$;

create or replace function booking._treatment_price(p_product bigint, p_persons integer) returns numeric
  language sql stable security definer set search_path to '' as $$
  select case when p.price_type = 'per_person' then p.price * p_persons
              else coalesce(p.price, 0) + coalesce(p.extra_person_price, 0) * greatest(p_persons - coalesce(p.included_persons, p_persons), 0) end
    from kb.products p where p.id = p_product $$;

-- Yhteinen tarjonta- ja luontitarkistus (virheet BK001 + koodi). p_lead: noudata vähimmäisetumatkaa (luonti/saatavuus); muutoksessa 48 h tarkistetaan erikseen
create or replace function booking._treatment_slot_check(p_product bigint, p_start timestamptz, p_persons integer, p_lead boolean default true) returns timestamptz
  language plpgsql stable security definer set search_path to '' as $function$
declare
  pc booking.product_config; p kb.products; ls timestamp; v_end timestamptz; v_code text; v_max integer; v_min integer;
  v_horizon integer := coalesce((booking._setting('public_treatment_horizon_days', '14'::jsonb) #>> '{}')::int, 14);
  v_lead integer := coalesce((booking._setting('public_treatment_min_lead_minutes', '120'::jsonb) #>> '{}')::int, 120);
begin
  select * into pc from booking.product_config where product_id = p_product;
  if not found or not pc.public_slots or not pc.bookable or not pc.shop_visible or pc.lifecycle <> 'current' then
    perform booking._err('not_bookable', 'Tuotetta ei voi varata verkossa');
  end if;
  select * into p from kb.products where id = p_product and active;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata verkossa'); end if;
  v_min := greatest(coalesce(pc.min_persons, 1), 1);
  v_max := booking._treatment_max_persons(p_product);
  if p_persons is null or p_persons < v_min or p_persons > v_max then
    perform booking._err('invalid_persons', format('Henkilömäärä voi olla %s–%s', v_min, v_max));
  end if;
  if p_start is null then perform booking._err('bad_slot', 'Valitse aika'); end if;
  ls := p_start at time zone booking._tz();
  if extract(second from ls) <> 0 or extract(minute from ls)::int % 30 <> 0 then
    perform booking._err('bad_slot', 'Aloitusaika ei ole varattavissa');
  end if;
  v_end := p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes));
  if p_lead and p_start < now() + make_interval(mins => v_lead) then
    perform booking._err('too_soon', 'Aika on liian lähellä – valitse myöhempi aika');
  end if;
  if ls::date > (now() at time zone booking._tz())::date + v_horizon then
    perform booking._err('too_far', format('Aikoja voi varata enintään %s päivän päähän', v_horizon));
  end if;
  if ls::date < (now() at time zone booking._tz())::date then perform booking._err('invalid_date', 'Päivä ei ole varattavissa'); end if;
  if (pc.public_weekdays is not null and not (extract(isodow from ls)::smallint = any (pc.public_weekdays))) or not booking._public_shift_day_open(ls::date) then
    perform booking._err('not_offered_day', 'Tälle päivälle ei ole tarjolla hoitoja');
  end if;
  v_code := booking._time_window_violation(p_product, p_start, v_end);
  if v_code = 'ritual_start' then
    perform booking._err('ritual_start', 'Rituaalin alkuaika voi olla vain ' || (select string_agg(to_char(t, 'HH24:MI'), ', ' order by t) from booking.time_window_rules r, unnest(r.allowed_starts) t
                          where r.class = 'ritual' and r.day_type = case when extract(isodow from ls) >= 6 then 'weekend' else 'weekday' end));
  elsif v_code = 'time_window' then
    perform booking._err('time_window', 'Aika ei ole varattavissa (hoitoaika)');
  end if;
  return v_end;
end $function$;

-- Slotin suunnitelman tila: 'ok' (täysi suunnitelma) | 'therapist_missing' (vain saunottaja puuttuu, varaus onnistuu therapist_missing-lipulla) | null (ei varattavissa: varattu/suljettu/kapasiteetti/saunottaja suljettu)
create or replace function booking._treatment_plan_status(p_product bigint, p_start timestamptz, p_end timestamptz, p_persons integer) returns text
  language plpgsql volatile security definer set search_path to '' as $function$
declare v_code text;
begin
  begin
    perform 1 from booking._plan_legs(p_product, p_start, p_end, p_persons, null, false, null, false);
    return 'ok';
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail;
    if v_code is distinct from 'no_therapist' then return null; end if;
  end;
  begin
    perform 1 from booking._plan_legs(p_product, p_start, p_end, p_persons, null, false, null, true);
    return 'therapist_missing';
  exception when sqlstate 'BK001' then return null;
  end;
end $function$;

create or replace function booking._treatment_plan_ok(p_product bigint, p_start timestamptz, p_end timestamptz, p_persons integer) returns boolean
  language sql volatile security definer set search_path to '' as $$ select booking._treatment_plan_status(p_product, p_start, p_end, p_persons) is not null $$;

-- Julkiset virhekoodit: moottorin saatavuusvirheet (tila varattu/suljettu/kapasiteetti/saunottaja suljettu) -> yksi 'slot_unavailable' (ei vuoda sisäisiä resurssinimiä)
create or replace function booking._public_slot_error(p_detail text, p_msg text) returns jsonb
  language sql immutable set search_path to '' as $$
  select case when p_detail in ('not_bookable', 'invalid_persons', 'bad_slot', 'too_soon', 'too_far', 'invalid_date', 'not_offered_day', 'ritual_start', 'time_window',
                                'change_too_late', 'price_change_requires_staff', 'vat_missing')
              then jsonb_build_object('ok', false, 'code', p_detail, 'message', p_msg)
              else jsonb_build_object('ok', false, 'code', 'slot_unavailable', 'message', 'Valittu aika ei ole enää varattavissa – valitse toinen aika') end $$;

-- ---------- saatavuus ----------
-- YHTEINEN YTIMEN: public_treatment_availability (verkkosivu) ja admin_treatment_availability (hallinta) käyttävät samaa laskentaa.
-- p_admin=false: täsmälleen verkkosivun säännöt (ruudukko 12:00-23:00, vähimmäisetumatka, horisontti, julkiset vuoropäivät/viikonpäivät, hoitoikkuna).
-- p_admin=true: ei vähimmäisetumatkaa/horisonttia (vain tulevaisuus); p_override=true lisäksi ohittaa päivä-, viikonpäivä- ja aikaikkunasäännöt (ruudukko 08:00-23:30) ja merkitsee rivit needs_override=true.
-- Resurssikonfliktit (varattu/suljettu/kapasiteetti/saunottaja suljettu) eivät koskaan ole ohitettavissa saatavuuslistassa.
create or replace function booking._treatment_availability_core(p_product_id bigint, p_from date, p_to date, p_persons integer, p_admin boolean, p_override boolean)
 returns table(product_id bigint, session_date date, starts_at timestamptz, ends_at timestamptz, duration_minutes integer, status text, persons integer, total numeric,
               price_type text, base_price numeric, included_persons integer, extra_person_price numeric, unit_price numeric, therapist_missing boolean, needs_override boolean)
 language plpgsql volatile security definer set search_path to ''
as $function$
declare
  pc booking.product_config; p kb.products; v_horizon integer := coalesce((booking._setting('public_treatment_horizon_days', '14'::jsonb) #>> '{}')::int, 14);
  v_lead integer := case when p_admin then 0 else coalesce((booking._setting('public_treatment_min_lead_minutes', '120'::jsonb) #>> '{}')::int, 120) end;
  v_today date := (now() at time zone booking._tz())::date; d date; t time; v_s timestamptz; v_e timestamptz; v_dur integer; v_total numeric; v_to date; v_st text; v_need boolean;
  v_day_ok boolean; v_win text;
begin
  select * into pc from booking.product_config x where x.product_id = p_product_id;
  if not found or pc.lifecycle <> 'current' then return; end if;
  if not p_admin and not (pc.public_slots and pc.bookable and pc.shop_visible) then return; end if;
  select * into p from kb.products x where x.id = p_product_id and x.active;
  if not found then return; end if;
  if p_persons is null or p_persons < greatest(coalesce(pc.min_persons, 1), 1) or p_persons > booking._treatment_max_persons(p_product_id) then return; end if;
  v_dur := coalesce(pc.duration_minutes, p.duration_minutes);
  v_total := booking._treatment_price(p_product_id, p_persons);
  v_to := case when p_admin then p_to else least(p_to, v_today + v_horizon) end;
  d := greatest(p_from, v_today);
  while d <= v_to loop
    v_day_ok := (pc.public_weekdays is null or extract(isodow from d)::smallint = any (pc.public_weekdays)) and booking._public_shift_day_open(d);
    if v_day_ok or (p_admin and p_override) then
      for t in select (g.m * interval '30 minutes')::time from generate_series(case when p_admin and p_override then 16 else 24 end, case when p_admin and p_override then 47 else 46 end) g(m) loop
        v_s := (d + t) at time zone booking._tz();
        v_e := v_s + make_interval(mins => v_dur);
        continue when v_s < now() + make_interval(mins => v_lead);
        v_win := booking._time_window_violation(p_product_id, v_s, v_e);
        v_need := (not v_day_ok) or v_win is not null;
        continue when v_need and not (p_admin and p_override);
        v_st := booking._treatment_plan_status(p_product_id, v_s, v_e, p_persons);
        continue when v_st is null;
        product_id := p_product_id; session_date := d; starts_at := v_s; ends_at := v_e; duration_minutes := v_dur; status := 'available'; persons := p_persons; total := v_total;
        price_type := p.price_type; base_price := p.price; included_persons := p.included_persons; extra_person_price := p.extra_person_price;
        unit_price := case when p.price_type = 'per_person' then p.price end;
        therapist_missing := (v_st = 'therapist_missing'); needs_override := v_need;
        return next;
      end loop;
    end if;
    d := d + 1;
  end loop;
  return;
end $function$;

-- VOLATILE: ottaa resurssilukot (_plan_legs/_check_claim) + kirjaa rate limit -osuman. lock_timeout suojaa kuormalta: kiireinen -> 'busy' (ei jonota).
create or replace function booking.public_treatment_availability(p_product_id bigint, p_from date, p_to date, p_persons integer default 1)
 returns table(product_id bigint, session_date date, starts_at timestamptz, ends_at timestamptz, duration_minutes integer, status text, persons integer, total numeric,
               price_type text, base_price numeric, included_persons integer, extra_person_price numeric, unit_price numeric)
 language plpgsql volatile security definer set search_path to '' set lock_timeout to '400ms'
as $function$
declare v_ip text := booking._client_ip();
begin
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 14 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 14 päivää)');
  end if;
  if v_ip is not null and not booking._rate_limit('avail:' || v_ip, (booking._setting('rl_avail_per_10min', '60'::jsonb) #>> '{}')::int, interval '10 minutes') then
    perform booking._err('rate_limited', 'Liian monta kyselyä, yritä hetken kuluttua uudelleen');
  end if;
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then return; end if;
  return query select c.product_id, c.session_date, c.starts_at, c.ends_at, c.duration_minutes, c.status, c.persons, c.total, c.price_type, c.base_price, c.included_persons,
                      c.extra_person_price, c.unit_price
                 from booking._treatment_availability_core(p_product_id, p_from, p_to, p_persons, false, false) c;
exception when lock_not_available then
  perform booking._err('busy', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
end $function$;

-- Hallinnan "Uusi varaus": sama ydin kuin verkkosivulla. Oikeus bookings.manage; p_override=true vaatii bookings.override + perustelun (>= 3 merkkiä) ja näyttää myös säännöistä (päivä/aikaikkuna/ruudukko 08:00-23:30) poikkeavat ajat (needs_override=true).
-- Näkyy myös julkaisemattomille tuotteille (public_slots/bookable/shop_visible eivät rajaa). Väli enintään 31 pv. therapist_missing=true: varaus onnistuu mutta saunottaja puuttuu (admin_review_list).
-- Varaus tehdään tämän jälkeen admin_create_resource_booking(...) (ylitystapauksessa p_override=true + p_override_reason).
create or replace function booking.admin_treatment_availability(p_product_id bigint, p_from date, p_to date, p_persons integer default 1, p_override boolean default false, p_override_reason text default null)
 returns table(product_id bigint, session_date date, starts_at timestamptz, ends_at timestamptz, duration_minutes integer, status text, persons integer, total numeric,
               price_type text, base_price numeric, included_persons integer, extra_person_price numeric, unit_price numeric, therapist_missing boolean, needs_override boolean)
 language plpgsql volatile security definer set search_path to '' set lock_timeout to '3s'
as $function$
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_override, false) then
    perform booking._require_permission('bookings.override');
    if p_override_reason is null or char_length(btrim(p_override_reason)) < 3 then perform booking._err('override_reason_required', 'Ylitys vaatii perustelun'); end if;
  end if;
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 31 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 31 päivää)');
  end if;
  return query select * from booking._treatment_availability_core(p_product_id, p_from, p_to, p_persons, true, coalesce(p_override, false));
end $function$;

-- ---------- luonti ----------
create or replace function booking.public_create_treatment_booking(p_product_id bigint, p_start timestamptz, p_persons integer, p_name text, p_email text, p_phone text,
    p_marketing_consent boolean default false, p_locale text default 'fi', p_note text default null, p_customer_kind text default 'private', p_company jsonb default null)
 returns jsonb
 language plpgsql volatile security definer set search_path to '' set lock_timeout to '3s'
as $function$
declare
  v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb;
  v_cust bigint; v_res jsonb; v_end timestamptz; v_total numeric; v_token uuid; v_detail text; v_msg text; v_pay_method text; v_order bigint;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
  -- suojakatkaisimet: pay_later ei vaadi maksua -> rajataan väärinkäyttö (sähköposti / kokonaismäärä)
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id join booking.reservations r on r.order_id = o.id
        join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where lower(c.email) = v_email and o.source_channel = 'web' and o.status = 'confirmed' and r.status = 'confirmed' and r.starts_at > now()
         and o.payment_status = 'unpaid') >= coalesce((booking._setting('public_treatment_max_open_per_email', '5'::jsonb) #>> '{}')::int, 5) then
    return jsonb_build_object('ok', false, 'code', 'too_many_open', 'message', 'Sinulla on jo useita tulevia varauksia – ota yhteyttä sähköpostitse');
  end if;
  if (select count(*) from booking.orders o join booking.reservations r on r.order_id = o.id join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where o.source_channel = 'web' and o.created_at > now() - interval '1 hour') >= coalesce((booking._setting('public_treatment_global_per_hour', '30'::jsonb) #>> '{}')::int, 30) then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Verkkovarauksia tehdään nyt poikkeuksellisen paljon – yritä myöhemmin uudelleen');
  end if;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);       -- uudelleenvalidointi luontihetkellä (päivä, aikaikkuna, ruudukko, henkilömäärä)
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_total := booking._treatment_price(p_product_id, p_persons);
    -- ei override-polkua; ei vapaata saunottajaa -> therapist_missing (booking_22) ellei päivä ole suljettu (therapist_closed nousee virheenä)
    v_res := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, v_cust, 'web', null, p_note, v_total, null, false, null, false, null);
    v_order := (v_res ->> 'order_id')::bigint;
    perform booking._stamp_order_billing(v_order, v_cust, v_company);
    v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
    insert into booking.payments(order_id, method, provider, status, amount) values (v_order, v_pay_method, 'manual', 'pending', v_total);
    update booking.orders set payment_status = 'unpaid' where id = v_order returning public_token into v_token;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_token, 'status', 'confirmed', 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'persons', p_persons, 'total', v_total, 'payment_mode', 'pay_later', 'payment_url', null, 'hold_expires_at', null,
                            'product_name', v_res -> 'product_name', 'customer_kind', v_kind, 'booking_kind', 'slots');
end $function$;

-- ---------- muutos (itse viimeistään N h ennen; sama tila; ei itseperuutusta) ----------
create or replace function booking.public_change_treatment_booking(p_token uuid, p_start timestamptz default null, p_persons integer default null)
 returns jsonb
 language plpgsql volatile security definer set search_path to '' set lock_timeout to '3s'
as $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; res booking.reservations; v_old booking.reservations; v_n int; v_res_id bigint; v_detail text; v_msg text; v_code text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_start timestamptz; v_end timestamptz; v_persons integer; v_total numeric; v_paid numeric; v_order_total numeric; v_item bigint;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chg:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if p_start is null and p_persons is null then return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi aika ja/tai henkilömäärä'); end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  begin
    select * into res from booking.reservations where id = v_res_id for update;
    if res.rule_id is not null or o.source_channel <> 'web' or not exists (select 1 from booking.product_config pc where pc.product_id = res.product_id and pc.public_slots) then
      return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
    end if;
    v_old := res;
    if res.starts_at - make_interval(hours => v_hours) < now() then
      perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen alkua – ota yhteyttä sähköpostitse', v_hours));
    end if;
    v_start := coalesce(p_start, res.starts_at);
    v_persons := coalesce(p_persons, res.persons);
    if p_start is not null and v_start - make_interval(hours => v_hours) < now() then
      perform booking._err('change_too_late', format('Uuden ajan pitää alkaa vähintään %s tuntia päästä', v_hours));
    end if;
    v_end := booking._treatment_slot_check(res.product_id, v_start, v_persons, false);
    -- sama tila (ei vaihdeta tilaa omatoimisesti): suunnitelma validoi rajat ja päällekkäisyydet (oma varaus jätetään huomiotta); saunottajaa ei vaadita
    perform 1 from booking._plan_legs(res.product_id, v_start, v_end, v_persons, res.space_id, false, res.id, true);
    v_total := booking._treatment_price(res.product_id, v_persons);
    select coalesce(sum(amount) filter (where status in ('paid', 'partially_refunded', 'refunded')), 0) into v_paid from booking.payments where order_id = o.id;
    if v_paid > 0 and v_total is distinct from o.total_gross then perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan'); end if;
    begin
      update booking.reservations set starts_at = v_start, ends_at = v_end, persons = v_persons where id = res.id returning * into res;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail;
      if v_code is distinct from 'no_therapist' then raise; end if;
      -- uudella ajalla ei vapaata saunottajaa: poistetaan saunottajaleg ja merkitään therapist_missing (ilmoitus Tapiolle triggerillä)
      delete from booking.reservation_legs where reservation_id = res.id and role = 'therapist';
      update booking.reservations set starts_at = v_start, ends_at = v_end, persons = v_persons, therapist_missing = true where id = res.id returning * into res;
    end;
    select id into v_item from booking.order_items where id = res.order_item_id;
    update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total where id = v_item;
    update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id returning total_gross into v_order_total;
    update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
    perform booking._refresh_order_payment(o.id);
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (null, booking._jwt_role(), 'reservations', res.id::text, 'CUSTOMER_CHANGE', to_jsonb(v_old), to_jsonb(res));
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at, 'persons', res.persons, 'total', v_order_total);
end $function$;

-- ---------- muokatut olemassa olevat julkiset funktiot (vain lisäyksiä; palautusrakenne ennallaan) ----------
CREATE OR REPLACE FUNCTION booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active))
$function$;

CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode,
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at) order by r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_change_booking(p_token uuid, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; v_res_id bigint; v_n int; v_out jsonb; v_detail text; v_msg text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chg:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if (p_rule_id is null) <> (p_date is null) or (p_rule_id is null and p_persons is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi vuoro ja/tai henkilömäärä');
  end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_date is not null and (p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  if exists (select 1 from booking.reservations r where r.id = v_res_id and r.rule_id is null) then   -- booking_25: aikaväli-/legipohjainen varaus -> oma muutosfunktio tai ei muutettavissa
    return jsonb_build_object('ok', false, 'code', case when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.id = v_res_id) then 'use_treatment_change' else 'not_changeable' end,
      'message', 'Tätä varausta ei voi muuttaa tällä toiminnolla – ota yhteyttä sähköpostitse',
      'change_via', case when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.id = v_res_id) then 'public_change_treatment_booking' end);
  end if;

  begin  -- alitransaktio: virhe kumoaa muutoksen kokonaan (vanha varaus säilyy) mutta rate limit -kirjaus säilyy
    v_out := booking._change_booking_core(v_res_id, p_rule_id, p_date, p_persons, true, v_hours, null, 'CUSTOMER_CHANGE');
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_out -> 'order_no', 'starts_at', v_out -> 'starts_at', 'ends_at', v_out -> 'ends_at',
                            'persons', v_out -> 'persons', 'total', v_out -> 'total');
end $function$;

-- ---------- oikeudet ----------
revoke all on function booking._therapist_missing_payload(booking.reservations), booking.reservations_notify_trg(), booking._public_shift_day_open(date), booking._time_window_violation(bigint, timestamptz, timestamptz),
  booking._treatment_max_persons(bigint), booking._treatment_price(bigint, integer), booking._treatment_slot_check(bigint, timestamptz, integer, boolean), booking._treatment_plan_ok(bigint, timestamptz, timestamptz, integer), booking._treatment_plan_status(bigint, timestamptz, timestamptz, integer),
  booking._treatment_availability_core(bigint, date, date, integer, boolean, boolean), booking.admin_treatment_availability(bigint, date, date, integer, boolean, text),
  booking._public_slot_error(text, text), booking.notifications_pull(text, text, integer), booking.notifications_ack(bigint[], text),
  booking.public_treatment_availability(bigint, date, date, integer), booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb),
  booking.public_change_treatment_booking(uuid, timestamptz, integer) from public, anon, authenticated;
grant execute on function booking._therapist_missing_payload(booking.reservations), booking._public_shift_day_open(date), booking._time_window_violation(bigint, timestamptz, timestamptz),
  booking._treatment_max_persons(bigint), booking._treatment_price(bigint, integer), booking._treatment_slot_check(bigint, timestamptz, integer, boolean), booking._treatment_plan_ok(bigint, timestamptz, timestamptz, integer), booking._treatment_plan_status(bigint, timestamptz, timestamptz, integer),
  booking._treatment_availability_core(bigint, date, date, integer, boolean, boolean),
  booking._public_slot_error(text, text), booking.notifications_pull(text, text, integer), booking.notifications_ack(bigint[], text) to service_role;
grant execute on function booking.admin_treatment_availability(bigint, date, date, integer, boolean, text) to authenticated, service_role;
grant execute on function booking.public_treatment_availability(bigint, date, date, integer), booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb),
  booking.public_change_treatment_booking(uuid, timestamptz, integer) to anon, authenticated, service_role;
