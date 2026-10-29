-- booking_202: tapahtumahallinnan osallistujat, muistiinpanot, viestit ja kerran peruutus.
-- Ei ajeta tästä työtilasta. Tietokannan omistaja ajaa migraation (dev, sitten prod).
--
-- 1) schedule_rules.cancelled_at: peruttu kerta (active=false vapauttaa tilavaraukset, varaukset jäävät).
-- 2) admin_event_rule_upsert sallii ajan siirron, vaikka kerralla on varauksia, ja siirtää varaukset sekä jonon
--    uuteen aikaan. Passivointi (active=false) on yhä estetty, jos varauksia on — peruutus on oma RPC.
-- 3) booking.event_participant_notes: henkilökunnan muistiinpano varausta kohti. RLS päällä, ei policyjä
--    (vain security definer). Poistuu varauksen mukana. Anonymisointi (varauksen vapaat tekstit nollataan
--    yhdessä) poistaa muistiinpanon.
-- 4) booking.event_messages: lähetysloki (aihe, teksti, määrät). Ei vastaanottajien sähköposteja.
-- 5) RPC:t admin_event_participants (henkilökunta), admin_event_participant_note_set (henkilökunta),
--    admin_event_occurrence_cancel (catalog.edit), admin_event_message_send (messages.edit; p_confirm=false
--    on esikatselu, true jonottaa _enqueue_email-lajilla event_message), admin_event_messages_list (henkilökunta).
-- 6) email_outbox.kind saa arvon event_message. email_outbox_claim liittää event_message-lohkon.
--    Asiakasviestin allekirjoitus on Tapio (send-emails). Maksuvälittäjän nimeä ei tallenneta eikä lähetetä.
-- Ei hintojen, ALV:n, tuoteosoitteiden eikä kassan muutoksia.
-- Rollback: ../rollbacks/20261028183000_booking_202_ROLLBACK.sql
set local lock_timeout = '5s';

alter table booking.schedule_rules add column if not exists cancelled_at timestamptz;
comment on column booking.schedule_rules.cancelled_at is
  'booking_202: tapahtumakerran peruutushetki. active=false vapauttaa tilavaraukset; liput jäävät.';

create index if not exists reservations_rule_idx on booking.reservations (rule_id) where rule_id is not null;

-- ---------- muistiinpanot ja viestiloki ----------
create table if not exists booking.event_participant_notes (
  id bigint generated always as identity primary key,
  reservation_id bigint not null unique references booking.reservations (id) on delete cascade,
  note text not null,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint event_participant_notes_len check (char_length(note) between 1 and 2000)
);
comment on table booking.event_participant_notes is
  'booking_202: henkilökunnan muistiinpano tapahtumavarauksesta. Asiakkaille ei näytetä. RLS, ei suoraa lukua.';
alter table booking.event_participant_notes enable row level security;
revoke all on booking.event_participant_notes from public, anon, authenticated;
grant all on booking.event_participant_notes to service_role;

create table if not exists booking.event_messages (
  id bigint generated always as identity primary key,
  product_id bigint not null references kb.products (id),
  rule_id bigint references booking.schedule_rules (id) on delete set null,
  subject text not null,
  body text not null,
  recipient_count integer not null,
  queued_count integer not null,
  skipped_count integer not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint event_messages_subject_len check (char_length(subject) between 1 and 200),
  constraint event_messages_body_len check (char_length(body) between 1 and 4000),
  constraint event_messages_counts check (recipient_count >= 0 and queued_count >= 0 and skipped_count >= 0)
);
comment on table booking.event_messages is
  'booking_202: tapahtuman osallistujaviestien loki. Ei vastaanottajalistaa. RLS, ei suoraa lukua.';
create index if not exists event_messages_product_idx on booking.event_messages (product_id, created_at desc);
alter table booking.event_messages enable row level security;
revoke all on booking.event_messages from public, anon, authenticated;
grant all on booking.event_messages to service_role;

-- Muistiinpanoa ei auditoida: audit_logia ei anonymisoida tämän taulun osalta (updated_by/updated_at riittävät).
drop trigger if exists audit_trg on booking.event_participant_notes;
drop trigger if exists audit_trg on booking.event_messages;
select booking._add_audit('booking.event_messages');

create or replace function booking.reservations_drop_event_note() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- booking_160 nollaa varauksen vapaat tekstit yhdessä vasta, kun asiakas on anonymisoitu (tai tilauksella ei ole asiakasta).
  -- Tavallinen muokkaus (esim. notes tyhjäksi) ei poista henkilökunnan muistiinpanoa.
  if new.notes is null and new.cancel_reason is null and new.therapist_exception_note is null
     and new.override_reason is null and new.hidden_reason is null
     and (old.notes is not null or old.cancel_reason is not null or old.therapist_exception_note is not null
          or old.override_reason is not null or old.hidden_reason is not null)
     and exists (select 1 from booking.orders o left join booking.customers c on c.id = o.customer_id
                  where o.id = new.order_id and (o.customer_id is null or c.anonymized_at is not null)) then
    delete from booking.event_participant_notes where reservation_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists reservations_drop_event_note on booking.reservations;
create trigger reservations_drop_event_note after update of notes, cancel_reason, therapist_exception_note, override_reason, hidden_reason
  on booking.reservations for each row execute function booking.reservations_drop_event_note();
revoke all on function booking.reservations_drop_event_note() from public, anon, authenticated;

-- Asiakkaan anonymisointi (privacy_retention_run asettaa anonymized_at) poistaa kaikki hänen tapahtumamuistiinpanonsa,
-- myös varauksista, joilla ei ole muita vapaita tekstejä (niitä booking_160 ei päivitä).
create or replace function booking.customers_drop_event_notes() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from booking.event_participant_notes n
   using booking.reservations x, booking.orders o
   where n.reservation_id = x.id and x.order_id = o.id and o.customer_id = new.id;
  return null;
end $$;
drop trigger if exists customers_drop_event_notes on booking.customers;
create trigger customers_drop_event_notes after update of anonymized_at on booking.customers
  for each row when (old.anonymized_at is null and new.anonymized_at is not null)
  execute function booking.customers_drop_event_notes();
revoke all on function booking.customers_drop_event_notes() from public, anon, authenticated;

-- Maksuvälittäjän nimeä ei hyväksytä asiakkaalle lähtevään tekstiin.
create or replace function booking._event_message_blocked(p_text text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_text, '') ~* '(montonio|visma|paybyway|mobilepay|vipps|paytrail|\ystripe\y|\ypaypal\y|\ynets\y)'
$$;
revoke all on function booking._event_message_blocked(text) from public, anon, authenticated;
grant execute on function booking._event_message_blocked(text) to service_role;

-- ---------- kerran JSON: peruutus ja varausten määrä ----------
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
    'sold_persons', (select coalesce(sum(x.persons), 0)::int from booking.reservations x
                      where x.rule_id = r.id and booking._res_active(x.status, x.hold_expires_at)),
    'reservation_count', (select count(*)::int from booking.reservations x where x.rule_id = r.id),
    'waitlist_count', (select count(*)::int from booking.waitlist_entries w where w.rule_id = r.id and w.status in ('waiting', 'notified')),
    'blocks', coalesce((select jsonb_agg(booking._event_block_json(b) order by b.sort_order, b.id)
                          from booking.event_resource_blocks b where b.rule_id = r.id), '[]'::jsonb))
  from booking.schedule_rules r where r.id = p_rule_id
$$;

-- ---------- ajan muutos sallittu, passivointi ei ----------
create or replace function booking.admin_event_rule_upsert(p_id bigint default null, p_product_id bigint default null, p_patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  allowed text[] := array['date','start_time','duration_minutes','max_persons','min_persons','deadline_minutes','label','label_en','active','price_variant_id'];
  k text; r booking.schedule_rules; p kb.products; pc booking.product_config;
  v_date date; v_start time; v_dur integer; v_max integer; v_min integer; v_deadline integer; v_label text; v_label_en text; v_active boolean;
  v_variant bigint; v_space bigint; v_sold integer; v_has_res boolean; v_id bigint; v_auto_label boolean := false;
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
    select coalesce(sum(x.persons), 0)::int, count(*) > 0 into v_sold, v_has_res
      from booking.reservations x where x.rule_id = r.id and booking._res_active(x.status, x.hold_expires_at);
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
      update booking.resources set capacity = v_sold where code = 'event_rule_' || r.id::text and capacity < v_sold;
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

create or replace function booking.admin_event_occurrence_cancel(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r booking.schedule_rules;
begin
  perform booking._require_permission('catalog.edit');
  select * into r from booking.schedule_rules where id = p_id for update;
  if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
  update booking.schedule_rules
     set cancelled_at = coalesce(cancelled_at, now()), active = false
   where id = r.id;
  -- Perutun kerran jono suljetaan, ettei lippujen peruutus lähetä "paikka vapautui" -viestejä.
  update booking.waitlist_entries w
     set status = 'cancelled', updated_at = now()
   where w.rule_id = r.id and w.status in ('waiting', 'notified');
  perform booking._event_sync_blocks(r.id);
  return booking._event_rule_json(r.id);
end $$;

-- ---------- osallistujat (vain se, mitä henkilökunta tarvitsee) ----------
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
      'reservation_id', x.id, 'order_id', o.id, 'order_no', o.order_no, 'rule_id', x.rule_id,
      'occurrence_label', sr.label, 'occurrence_label_en', sr.label_en, 'starts_at', x.starts_at,
      'name', c.name, 'email', c.email, 'phone', c.phone, 'persons', x.persons,
      'order_status', o.status, 'payment_status', o.payment_status, 'reservation_status', x.status,
      'booked_at', o.created_at, 'customer_note', nullif(left(coalesce(o.customer_note, ''), 1000), ''),
      'option_label', po.name, 'option_label_en', po.name_en,
      'adults', case when x.participant_breakdown ->> 'adults' ~ '^[0-9]{1,3}$' then (x.participant_breakdown ->> 'adults')::int end,
      'children', case when x.participant_breakdown ->> 'children' ~ '^[0-9]{1,3}$' then (x.participant_breakdown ->> 'children')::int end,
      'staff_note', n.note
    ) order by x.starts_at, c.name, x.id)
    from booking.reservations x
    join booking.schedule_rules sr on sr.id = x.rule_id and sr.kind = 'event' and sr.product_id = p_product_id
    join booking.orders o on o.id = x.order_id
    left join booking.customers c on c.id = o.customer_id
    left join booking.product_options po on po.id = x.product_option_id
    left join booking.event_participant_notes n on n.reservation_id = x.id
    where (p_rule_id is null or x.rule_id = p_rule_id)
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

-- ---------- viesti: esikatselu (p_confirm false) tai lähetys ----------
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
      'signature', 'Tapio', 'subject', v_subject,
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
  return jsonb_build_object('ok', true, 'sent', true, 'id', v_log, 'recipient_count', v_n, 'queued_count', v_queued, 'skipped_count', v_skipped, 'signature', 'Tapio');
end $$;

create or replace function booking.admin_event_messages_list(p_product_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  if not exists (select 1 from kb.products p where p.id = p_product_id and p.category in ('event', 'training')) then
    perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus');
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'product_id', m.product_id, 'rule_id', m.rule_id, 'subject', m.subject, 'body', m.body,
      'recipient_count', m.recipient_count, 'queued_count', m.queued_count, 'skipped_count', m.skipped_count,
      'created_at', m.created_at
    ) order by m.created_at desc, m.id desc)
    from booking.event_messages m where m.product_id = p_product_id
  ), '[]'::jsonb);
end $$;

-- ---------- sähköpostilaji ----------
do $k$
declare def text; expr text;
begin
  select pg_get_constraintdef(c.oid) into def
    from pg_constraint c
   where c.conrelid = 'booking.email_outbox'::regclass and c.conname = 'email_outbox_kind_check';
  if def is null then raise exception 'booking_202: email_outbox_kind_check puuttuu'; end if;
  if position('event_message' in def) > 0 then return; end if;
  if def like '%ARRAY[%' then
    expr := replace(def, 'ARRAY[', 'ARRAY[''event_message''::text, ');
  else
    raise exception 'booking_202: email_outbox_kind_check muotoa ei tunnistettu';
  end if;
  execute 'alter table booking.email_outbox drop constraint email_outbox_kind_check';
  execute 'alter table booking.email_outbox add constraint email_outbox_kind_check ' || expr;
end $k$;

-- booking_190:n claim + event_message-lohko (aihe, teksti, tapahtuma, aika). Ei maksutietoja.
create or replace function booking.email_outbox_claim(p_limit integer default 20)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    when z.item->>'kind' = 'payment_link'
    then z.item || coalesce((select jsonb_build_object('voucher_difference', jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference'))
                               from booking.email_outbox e where e.id = (z.item->>'id')::bigint and e.payload ->> 'variant' = 'voucher_difference'), '{}'::jsonb)
    when z.item->>'kind' = 'voucher_claim_received'
    then z.item || coalesce((select jsonb_build_object('order', (z.item->'order') || jsonb_build_object('instructions', booking._order_short_instructions(e.order_id, coalesce(nullif(e.locale, ''), o.locale, 'fi'))))
                               from booking.email_outbox e join booking.orders o on o.id = e.order_id where e.id = (z.item->>'id')::bigint and jsonb_typeof(z.item->'order') = 'object'), '{}'::jsonb)
                || coalesce((select jsonb_build_object('voucher_claim', jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
                                   'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name))
                               from booking.email_outbox e join booking.voucher_claims vc on vc.order_id = e.order_id
                              where e.id = (z.item->>'id')::bigint and coalesce(z.item #>> '{voucher_claim,status}', 'cancelled') in ('cancelled', 'expired')
                                and vc.status in ('open', 'processing', 'problem', 'redeemed')
                              order by vc.created_at, vc.id limit 1), '{}'::jsonb)
    when z.item->>'kind' = 'unpaid_booking_cancelled'
    then z.item || coalesce((select jsonb_build_object('unpaid_booking', jsonb_strip_nulls(jsonb_build_object(
                  'retry_url', e.payload ->> 'retry_url',
                  'product_name', case when e.locale = 'en' then coalesce(nullif(e.payload ->> 'product_name_en', ''), e.payload ->> 'product_name') else e.payload ->> 'product_name' end,
                  'starts_at', e.payload -> 'starts_at')))
                from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    when z.item->>'kind' = 'event_message'
    then z.item || coalesce((select jsonb_build_object('event_message', jsonb_strip_nulls(jsonb_build_object(
                  'subject', e.payload ->> 'subject', 'body', e.payload ->> 'body',
                  'event_name', e.payload ->> 'event_name', 'event_name_en', e.payload ->> 'event_name_en',
                  'when_text', e.payload ->> 'when_text', 'starts_at', e.payload -> 'starts_at')))
                from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'booking.admin_event_participants(bigint, bigint)',
    'booking.admin_event_participant_note_set(bigint, text)',
    'booking.admin_event_occurrence_cancel(bigint)',
    'booking.admin_event_message_send(bigint, bigint, text, text, boolean)',
    'booking.admin_event_messages_list(bigint)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

comment on function booking.admin_event_participants(bigint, bigint) is
  'booking_202: tapahtuman osallistujat (nimi, yhteystieto, henkilöt, tila, asiakkaan viesti, valinta, muistiinpano). Henkilökunta. Ei maksuvälittäjää.';
comment on function booking.admin_event_participant_note_set(bigint, text) is
  'booking_202: henkilökunnan muistiinpano tapahtumavaraukselle. Tyhjä poistaa. Henkilökunta.';
comment on function booking.admin_event_occurrence_cancel(bigint) is
  'booking_202: peruu kerran (cancelled_at, active=false). catalog.edit. Varaukset jäävät, poisto on yhä estetty.';
comment on function booking.admin_event_message_send(bigint, bigint, text, text, boolean) is
  'booking_202: esikatselu (p_confirm false) tai lähetys tapahtuman osallistujille (_enqueue_email event_message). messages.edit. Allekirjoitus Tapio.';
comment on function booking.admin_event_messages_list(bigint) is
  'booking_202: lähetettyjen tapahtumaviestien loki. Henkilökunta. Ei vastaanottajien osoitteita.';
