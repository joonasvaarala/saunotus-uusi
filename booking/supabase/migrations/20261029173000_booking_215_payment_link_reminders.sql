-- booking_215: maksamattomien maksulinkkien automaattiset muistutukset ja hallinnan seuranta
-- (Joonas 29.10.2026).
--
-- Ennakkomaksu (link_expires_at asetettu, linkki = eräpäivä yli 2 h luonnista): muistutus, kun linkki on ollut
-- avoinna payment_link.remind_prepaid_after_hours (oletus 72), ja toinen payment_link.remind_before_expiry_hours
-- (oletus 24) ennen eräpäivää. Jos eräpäivään on luonnista enintään (72+24) h, vain eräpäivää edeltävä muistutus.
-- Viestissä kerrotaan, että varaus perutaan, ellei maksua ole maksettu eräpäivään mennessä.
-- Paikan päällä annettu linkki (link_expires_at null ja raw.paylink = no_deadline): muistutus
-- payment_link.remind_onsite_interval_hours (oletus 72) välein, enintään payment_link.remind_onsite_max (oletus 4).
-- Sen jälkeen reminders_needs_action = true (hallinnassa "vaatii toimenpiteitä").
--
-- Yhteistä: lähetys vain payment_link.remind_window (oletus 10-18, lopputunti ei kuulu) Europe/Helsinki;
-- pending + provider <> manual + external_source null (maksu ja tilaus); maksettu/peruttu/vanhentunut lopettaa jonon;
-- sama maksulinkki; dedupe payment_link_reminder:<payment_id>:<n>; allekirjoitus Tapio (pohja).
-- Lyhyt kassan maksuistunto (link_expires_at - created_at <= 2 h, tai null ilman no_deadline-merkintää) ei ole linkki.
--
-- Ajastus: migraatio EI luo pg_cron-jobia eikä lähetä viestejä. payment_link.reminders_enabled = false.
-- Sweep palauttaa 0, kun asetus ei ole true. DEV:ssä älä kytke. Tuotannossa aja erikseen
-- booking/supabase/manual/booking_215_payment_link_reminders_cron.sql (cron vain jos cron-skeema on olemassa).
-- Jos asetus on jo true ja cron-skeema löytyy (uusinta-ajo), job luodaan tässäkin, paitsi booking.skip_cron = on.

alter table booking.payments
  add column if not exists reminders_paused_at timestamptz,
  add column if not exists reminders_handled_at timestamptz,
  add column if not exists reminders_needs_action boolean not null default false;

comment on column booking.payments.reminders_paused_at is
  'booking_215: automaattiset maksulinkkimuistutukset keskeytetty. Käsinlähetys on yhä sallittu.';
comment on column booking.payments.reminders_handled_at is
  'booking_215: linkki merkitty hoidetuksi ilman maksupolkua. Avoimesta seurantanäkymästä pois.';
comment on column booking.payments.reminders_needs_action is
  'booking_215: paikan päällä annettu linkki, jolle on lähetetty enimmäismäärä muistutuksia, tai vastaanottaja puuttuu.';

create table if not exists booking.payment_link_reminders (
  id              bigint generated always as identity primary key,
  payment_id      bigint not null references booking.payments(id) on delete cascade,
  reminder_no     integer not null check (reminder_no between 1 and 99),
  kind            text not null check (kind in ('prepaid_unpaid', 'prepaid_before_expiry', 'onsite', 'manual', 'skipped')),
  emailed         boolean not null default true,
  sent_at         timestamptz not null default now(),
  email_outbox_id bigint,
  created_at      timestamptz not null default now(),
  unique (payment_id, reminder_no)
);
create index if not exists payment_link_reminders_payment_idx on booking.payment_link_reminders(payment_id, reminder_no);
comment on table booking.payment_link_reminders is
  'booking_215: lähetetyt maksulinkkimuistutukset. dedupe on myös email_outbox.dedupe_key (payment_link_reminder:<id>:<n>).';

alter table booking.payment_link_reminders enable row level security;
revoke all on table booking.payment_link_reminders from public, anon, authenticated;
grant all on table booking.payment_link_reminders to service_role;

create index if not exists payments_open_paylink_idx
  on booking.payments (created_at, id)
  where status = 'pending' and external_source is null and provider <> 'manual';

insert into booking.settings(key, value, description, is_public) values
  ('payment_link.reminders_enabled', 'false'::jsonb,
   'Automaattiset maksulinkkimuistutukset. false = sweep ei lähetä (DEV). Tuotannossa manual/booking_215_payment_link_reminders_cron.sql.', false),
  ('payment_link.remind_prepaid_after_hours', '72'::jsonb,
   'Ennakkomaksulinkki: ensimmäinen muistutus, kun linkki on ollut avoinna näin monta tuntia.', false),
  ('payment_link.remind_before_expiry_hours', '24'::jsonb,
   'Ennakkomaksulinkki: muistutus näin monta tuntia ennen eräpäivää (link_expires_at).', false),
  ('payment_link.remind_onsite_interval_hours', '72'::jsonb,
   'Paikan päällä annettu linkki (ei eräpäivää): muistutusväli tunteina.', false),
  ('payment_link.remind_onsite_max', '4'::jsonb,
   'Paikan päällä annettu linkki: automaattisten muistutusten enimmäismäärä. Sen jälkeen vaatii toimenpiteitä.', false),
  ('payment_link.remind_window', '"10-18"'::jsonb,
   'Automaattisten muistutusten lähetysikkuna Europe/Helsinki, tunnit alku-loppu. Lopputunti ei kuulu (10-18 = 10:00–17:59).', false)
on conflict (key) do nothing;

-- ---------- sähköpostilaji ----------
do $k$
declare def text; expr text;
begin
  select pg_get_constraintdef(c.oid) into def
    from pg_constraint c
   where c.conrelid = 'booking.email_outbox'::regclass and c.conname = 'email_outbox_kind_check';
  if def is null then raise exception 'booking_215: email_outbox_kind_check puuttuu'; end if;
  if position('payment_link_reminder' in def) > 0 then return; end if;
  if def like '%ARRAY[%' then
    expr := replace(def, 'ARRAY[', 'ARRAY[''payment_link_reminder''::text, ');
  else
    raise exception 'booking_215: email_outbox_kind_check muotoa ei tunnistettu';
  end if;
  execute 'alter table booking.email_outbox drop constraint email_outbox_kind_check';
  execute 'alter table booking.email_outbox add constraint email_outbox_kind_check ' || expr;
end $k$;

-- ---------- apurit ----------
create or replace function booking._plr_hours(p_key text, p_default integer, p_min integer, p_max integer)
returns integer
language plpgsql stable security definer set search_path = '' as $$
declare v text := booking._setting(p_key, to_jsonb(p_default)) #>> '{}'; n integer;
begin
  if v is null or v !~ '^[0-9]{1,5}$' then return p_default; end if;
  n := v::integer;
  if n < p_min or n > p_max then return p_default; end if;
  return n;
end $$;

create or replace function booking._plr_enabled()
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(booking._setting('payment_link.reminders_enabled', 'false'::jsonb) #>> '{}', 'false') in ('true', 't')
$$;

create or replace function booking._plr_window()
returns table(lo integer, hi integer)
language plpgsql stable security definer set search_path = '' as $$
declare s text := coalesce(booking._setting('payment_link.remind_window', '"10-18"'::jsonb) #>> '{}', '10-18');
begin
  if s !~ '^[0-9]{1,2}-[0-9]{1,2}$' then s := '10-18'; end if;
  lo := split_part(s, '-', 1)::integer;
  hi := split_part(s, '-', 2)::integer;
  if lo < 0 or hi > 24 or lo >= hi then lo := 10; hi := 18; end if;
  return next;
end $$;

create or replace function booking._plr_in_window(p_ts timestamptz)
returns boolean
language sql stable security definer set search_path = '' as $$
  select extract(hour from p_ts at time zone 'Europe/Helsinki')::integer >= w.lo
     and extract(hour from p_ts at time zone 'Europe/Helsinki')::integer < w.hi
    from booking._plr_window() w
$$;

create or replace function booking._plr_next_open(p_due timestamptz)
returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare w record; local_ts timestamp; d date;
begin
  if p_due is null then return null; end if;
  if booking._plr_in_window(p_due) then return p_due; end if;
  select * into w from booking._plr_window();
  local_ts := p_due at time zone 'Europe/Helsinki';
  d := local_ts::date;
  if extract(hour from local_ts)::integer >= w.hi then d := d + 1; end if;
  return (d::timestamp + make_interval(hours => w.lo)) at time zone 'Europe/Helsinki';
end $$;

-- Maksulinkki, ei lyhyt kassan maksuistunto. prepaid = eräpäivä; onsite = ei takarajaa.
create or replace function booking._plr_link_kind(p_created timestamptz, p_expires timestamptz, p_raw jsonb)
returns text
language sql immutable set search_path = '' as $$
  select case
    when p_expires is null and coalesce(p_raw ->> 'paylink', '') = 'no_deadline' then 'onsite'
    when p_expires is not null and p_expires > p_created + interval '2 hours' then 'prepaid'
    else null
  end
$$;

create or replace function booking._plr_is_tracked(p_id bigint, p_now timestamptz default now())
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from booking.payments p
      join booking.orders o on o.id = p.order_id
     where p.id = p_id
       and p.status = 'pending'
       and p.provider <> 'manual'
       and p.external_source is null
       and o.external_source is null
       and p.reminders_handled_at is null
       and booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) is not null
       and (p.link_expires_at is null or p.link_expires_at > coalesce(p_now, now()))
  )
$$;

-- Seuraava automaattinen muistutus. next on null, kun automaattisia ei ole jäljellä.
-- due = next.due_at <= p_now. skip = ennakkomuistutuksen numerot, jotka ohitetaan (molemmat myöhässä).
create or replace function booking._plr_plan(p_payment_id bigint, p_created timestamptz, p_expires timestamptz, p_raw jsonb, p_now timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_kind text := booking._plr_link_kind(p_created, p_expires, p_raw);
  v_after integer; v_before integer; v_interval integer; v_max integer;
  v_sent integer; v_last timestamptz; v_next_no integer; v_due timestamptz;
  v_has1 boolean; v_has2 boolean; v_first_ok boolean;
  v_due1 timestamptz; v_due2 timestamptz;
  v_skip jsonb := '[]'::jsonb; v_next jsonb;
begin
  if v_kind is null or p_now is null then
    return jsonb_build_object('needs_action', false, 'due', false);
  end if;
  if v_kind = 'prepaid' then
    v_after := booking._plr_hours('payment_link.remind_prepaid_after_hours', 72, 1, 2160);
    v_before := booking._plr_hours('payment_link.remind_before_expiry_hours', 24, 1, 720);
    v_due1 := p_created + make_interval(hours => v_after);
    v_due2 := p_expires - make_interval(hours => v_before);
    -- Yli (jälki + ennen) tuntia: molemmat. Tasan tai alle: vain eräpäivää edeltävä (ne osuisivat samaan hetkeen tai väärään järjestykseen).
    v_first_ok := p_expires > p_created + make_interval(hours => v_after + v_before);
    select exists (select 1 from booking.payment_link_reminders r where r.payment_id = p_payment_id and r.reminder_no = 1),
           exists (select 1 from booking.payment_link_reminders r where r.payment_id = p_payment_id and r.reminder_no = 2)
      into v_has1, v_has2;
    if v_first_ok and not v_has1 and v_due2 <= p_now then
      v_skip := '[1]'::jsonb;
      v_has1 := true;
    end if;
    if v_first_ok and not v_has1 then
      v_next := jsonb_build_object('no', 1, 'kind', 'prepaid_unpaid', 'due_at', v_due1, 'cancel', true);
      return jsonb_strip_nulls(jsonb_build_object('link_kind', 'prepaid', 'skip', v_skip, 'needs_action', false,
        'next', v_next, 'due', v_due1 <= p_now));
    end if;
    if not v_has2 then
      v_next := jsonb_build_object('no', 2, 'kind', 'prepaid_before_expiry', 'due_at', v_due2, 'cancel', true);
      return jsonb_strip_nulls(jsonb_build_object('link_kind', 'prepaid', 'skip', v_skip, 'needs_action', false,
        'next', v_next, 'due', v_due2 <= p_now));
    end if;
    return jsonb_build_object('link_kind', 'prepaid', 'skip', v_skip, 'needs_action', false, 'due', false);
  end if;

  v_interval := booking._plr_hours('payment_link.remind_onsite_interval_hours', 72, 1, 2160);
  v_max := booking._plr_hours('payment_link.remind_onsite_max', 4, 1, 20);
  select count(*)::integer, max(r.sent_at)
    into v_sent, v_last
    from booking.payment_link_reminders r
   where r.payment_id = p_payment_id and r.kind = 'onsite' and r.emailed;
  if v_sent >= v_max then
    return jsonb_build_object('link_kind', 'onsite', 'skip', '[]'::jsonb, 'needs_action', true, 'due', false);
  end if;
  v_next_no := v_sent + 1;
  v_due := p_created + make_interval(hours => v_interval * v_next_no);
  if v_last is not null then
    v_due := greatest(v_due, v_last + make_interval(hours => v_interval));
  end if;
  v_next := jsonb_build_object('no', v_next_no, 'kind', 'onsite', 'due_at', v_due, 'cancel', false);
  return jsonb_build_object('link_kind', 'onsite', 'skip', '[]'::jsonb, 'needs_action', false,
    'next', v_next, 'due', v_due <= p_now);
end $$;

create or replace function booking._plr_enqueue(
  p_payment_id bigint, p_order_id bigint, p_no integer, p_kind text, p_due timestamptz, p_cancel boolean, p_at timestamptz)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_ok boolean; v_key text := 'payment_link_reminder:' || p_payment_id || ':' || p_no; v_id bigint;
begin
  insert into booking.payment_link_reminders(payment_id, reminder_no, kind, emailed, sent_at)
  values (p_payment_id, p_no, p_kind, true, coalesce(p_at, now()))
  on conflict (payment_id, reminder_no) do nothing
  returning id into v_id;
  if v_id is null then return false; end if;
  v_ok := booking._enqueue_email('payment_link_reminder', p_order_id, null, p_payment_id, v_key,
    jsonb_build_object('reminder_no', p_no, 'reminder_kind', p_kind, 'cancel_if_unpaid', coalesce(p_cancel, false), 'due_at', p_due));
  if not v_ok then
    if exists (select 1 from booking.email_outbox e where e.dedupe_key = v_key) then
      update booking.payment_link_reminders set email_outbox_id = (select id from booking.email_outbox where dedupe_key = v_key) where id = v_id;
      return false;
    end if;
    update booking.payment_link_reminders set emailed = false, kind = 'skipped' where id = v_id;
    update booking.payments set reminders_needs_action = true, reminders_paused_at = coalesce(reminders_paused_at, now()) where id = p_payment_id;
    return false;
  end if;
  update booking.payment_link_reminders
     set email_outbox_id = (select id from booking.email_outbox where dedupe_key = v_key)
   where id = v_id;
  if p_kind = 'onsite' and p_no >= booking._plr_hours('payment_link.remind_onsite_max', 4, 1, 20) then
    update booking.payments set reminders_needs_action = true where id = p_payment_id;
  end if;
  return true;
end $$;

create or replace function booking.payment_link_reminders_sweep(p_now timestamptz default now())
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  n integer := 0;
  r record;
  v_plan jsonb;
  v_next jsonb;
begin
  if not booking._plr_enabled() then return 0; end if;
  if not booking._plr_in_window(v_now) then return 0; end if;
  for r in
    select p.id, p.order_id, p.created_at, p.link_expires_at, p.raw, p.reminders_needs_action
      from booking.payments p
      join booking.orders o on o.id = p.order_id
     where p.status = 'pending'
       and p.provider <> 'manual'
       and p.external_source is null
       and o.external_source is null
       and p.reminders_handled_at is null
       and p.reminders_paused_at is null
       and booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) is not null
       and (p.link_expires_at is null or p.link_expires_at > v_now)
     order by p.id
     for update of p skip locked
  loop
    v_plan := booking._plr_plan(r.id, r.created_at, r.link_expires_at, r.raw, v_now);
    if coalesce((v_plan ->> 'needs_action')::boolean, false) and not r.reminders_needs_action then
      update booking.payments set reminders_needs_action = true where id = r.id;
    end if;
    if jsonb_typeof(v_plan -> 'skip') = 'array' then
      insert into booking.payment_link_reminders(payment_id, reminder_no, kind, emailed, sent_at)
      select r.id, x::integer, 'skipped', false, v_now
        from jsonb_array_elements_text(v_plan -> 'skip') x
      on conflict (payment_id, reminder_no) do nothing;
    end if;
    v_next := v_plan -> 'next';
    if v_next is null or jsonb_typeof(v_next) = 'null' then continue; end if;
    if not coalesce((v_plan ->> 'due')::boolean, false) then continue; end if;
    if booking._plr_enqueue(r.id, r.order_id, (v_next ->> 'no')::integer, v_next ->> 'kind',
                            (v_next ->> 'due_at')::timestamptz, (v_next ->> 'cancel')::boolean, v_now) then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function booking.payments_reminder_stop_trg()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and old.status = 'pending' and new.status is distinct from 'pending' then
    new.reminders_needs_action := false;
    update booking.email_outbox
       set status = 'skipped', last_error = 'payment_not_pending', locked_at = null
     where payment_id = new.id
       and kind = 'payment_link_reminder'
       and status in ('pending', 'failed');
  end if;
  return new;
end $$;

drop trigger if exists payments_reminder_stop on booking.payments;
create trigger payments_reminder_stop
  before update of status on booking.payments
  for each row execute function booking.payments_reminder_stop_trg();

-- ---------- hallinta ----------
create or replace function booking.admin_list_payment_link_watch(
  p_search text default null, p_status text default null, p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_num bigint; v_like text; v_lim integer := coalesce(p_limit, 50); v_off integer := greatest(coalesce(p_offset, 0), 0);
  v_total integer; v_rows jsonb; v_now timestamptz := now();
begin
  perform booking._require_permission('payments.manage');
  if p_status is not null and p_status not in ('watching', 'paused', 'needs_action') then
    perform booking._err('invalid_param', 'Tuntematon tila');
  end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select p.id, p.order_id, o.order_no, p.amount, c.name as customer_name, p.created_at, p.link_expires_at, p.raw,
           p.reminders_paused_at, p.reminders_needs_action,
           booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) as link_kind,
           booking._plr_plan(p.id, p.created_at, p.link_expires_at, p.raw, v_now) as plan
      from booking.payments p
      join booking.orders o on o.id = p.order_id
      left join booking.customers c on c.id = o.customer_id
     where p.status = 'pending'
       and p.provider <> 'manual'
       and p.external_source is null
       and o.external_source is null
       and p.reminders_handled_at is null
       and booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) is not null
       and (p.link_expires_at is null or p.link_expires_at > v_now)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or p.id = v_num))
            or (v_like is not null and (c.name ilike v_like escape '\' or c.email ilike v_like escape '\')))
  ), marked as (
    select b.*,
           case when b.reminders_needs_action or coalesce((b.plan ->> 'needs_action')::boolean, false) then 'needs_action'
                when b.reminders_paused_at is not null then 'paused'
                else 'watching' end as watch_status,
           case when b.reminders_paused_at is not null or coalesce((b.plan ->> 'needs_action')::boolean, false) or b.reminders_needs_action
                  or (b.plan #>> '{next,due_at}') is null then null
                else booking._plr_next_open(greatest((b.plan #>> '{next,due_at}')::timestamptz, v_now)) end as next_at
      from base b
  ), filtered as (
    select * from marked where p_status is null or watch_status = p_status
  ), page as (
    select f.*, row_number() over (order by (f.watch_status = 'needs_action') desc, f.created_at asc, f.id asc) as rn
      from filtered f
  )
  select (select count(*) from filtered),
         coalesce(jsonb_agg(jsonb_build_object(
           'payment_id', p.id, 'order_id', p.order_id, 'order_no', p.order_no, 'amount', p.amount,
           'customer_name', p.customer_name, 'created_at', p.created_at, 'link_expires_at', p.link_expires_at,
           'link_kind', p.link_kind, 'status', p.watch_status, 'paused_at', p.reminders_paused_at,
           'needs_action', p.watch_status = 'needs_action', 'next_reminder_at', p.next_at,
           'reservation', (
             select jsonb_build_object('product_name', coalesce(it.product_name, ''), 'starts_at', r.starts_at,
                      'count', (select count(*) from booking.reservations r2 where r2.order_id = p.order_id and r2.status <> 'cancelled'))
               from booking.reservations r
               left join booking.order_items it on it.id = r.order_item_id
              where r.order_id = p.order_id and r.status <> 'cancelled'
              order by r.starts_at nulls last, r.id limit 1),
           'reminders', coalesce((
             select jsonb_agg(jsonb_build_object('no', x.reminder_no, 'at', x.sent_at, 'kind', x.kind) order by x.reminder_no)
               from booking.payment_link_reminders x where x.payment_id = p.id and x.emailed), '[]'::jsonb),
           'reminder_count', (select count(*) from booking.payment_link_reminders x where x.payment_id = p.id and x.emailed),
           'last_reminder_at', (select max(x.sent_at) from booking.payment_link_reminders x where x.payment_id = p.id and x.emailed)
         ) order by p.rn), '[]'::jsonb)
    into v_total, v_rows
    from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', coalesce(v_total, 0), 'rows', coalesce(v_rows, '[]'::jsonb));
end $$;

create or replace function booking.admin_payment_link_remind_now(p_payment_id bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p booking.payments; v_plan jsonb; v_next jsonb; v_no integer; v_kind text; v_cancel boolean; v_ok boolean; v_at timestamptz := now();
begin
  perform booking._require_permission('payments.manage');
  select * into p from booking.payments where id = p_payment_id for update;
  if not found or not booking._plr_is_tracked(p_payment_id, v_at) then
    perform booking._err('link_closed', 'Maksulinkki ei ole enää avoinna');
  end if;
  v_plan := booking._plr_plan(p.id, p.created_at, p.link_expires_at, p.raw, v_at);
  if jsonb_typeof(v_plan -> 'skip') = 'array' then
    insert into booking.payment_link_reminders(payment_id, reminder_no, kind, emailed, sent_at)
    select p.id, x::integer, 'skipped', false, v_at from jsonb_array_elements_text(v_plan -> 'skip') x
    on conflict (payment_id, reminder_no) do nothing;
    v_plan := booking._plr_plan(p.id, p.created_at, p.link_expires_at, p.raw, v_at);
  end if;
  v_next := v_plan -> 'next';
  if v_next is not null and jsonb_typeof(v_next) <> 'null' then
    v_no := (v_next ->> 'no')::integer;
    v_kind := v_next ->> 'kind';
    v_cancel := (v_next ->> 'cancel')::boolean;
  else
    select coalesce(max(reminder_no), 0) + 1 into v_no from booking.payment_link_reminders where payment_id = p.id;
    v_kind := 'manual';
    v_cancel := booking._plr_link_kind(p.created_at, p.link_expires_at, p.raw) = 'prepaid';
  end if;
  v_ok := booking._plr_enqueue(p.id, p.order_id, v_no, v_kind, coalesce((v_next ->> 'due_at')::timestamptz, v_at), v_cancel, v_at);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.payments', p.id::text, 'PAYMENT_LINK_REMIND_NOW',
          jsonb_build_object('reminder_no', v_no, 'kind', v_kind, 'queued', v_ok));
  return jsonb_build_object('ok', true, 'queued', v_ok, 'reminder_no', v_no, 'kind', v_kind);
end $$;

create or replace function booking.admin_payment_link_pause_reminders(p_payment_id bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p booking.payments; v_at timestamptz := now();
begin
  perform booking._require_permission('payments.manage');
  select * into p from booking.payments where id = p_payment_id for update;
  if not found or not booking._plr_is_tracked(p_payment_id, v_at) then
    perform booking._err('link_closed', 'Maksulinkki ei ole enää avoinna');
  end if;
  if p.reminders_paused_at is null then
    update booking.payments set reminders_paused_at = v_at where id = p.id;
  end if;
  update booking.email_outbox
     set status = 'skipped', last_error = 'reminders_paused', locked_at = null
   where payment_id = p.id and kind = 'payment_link_reminder' and status in ('pending', 'failed');
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.payments', p.id::text, 'PAYMENT_LINK_REMINDERS_PAUSED', jsonb_build_object('at', v_at));
  return jsonb_build_object('ok', true, 'paused_at', coalesce(p.reminders_paused_at, v_at));
end $$;

-- Merkitse hoidetuksi: olemassa oleva käsin kirjattu maksu (admin_record_payment) peruu avoimen linkin ja tekee kuitin kirjanpitoon.
-- Kuittisähköpostia ei lähde (booking_191, email.receipt_auto_send = false).
create or replace function booking.admin_payment_link_mark_handled(p_payment_id bigint, p_method text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p booking.payments; v jsonb; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform booking._require_permission('payments.manage');
  if p_method is null or btrim(p_method) = '' then perform booking._err('invalid_param', 'Valitse maksutapa'); end if;
  if p_method in ('cash', 'gift_card', 'partner_voucher', 'pay_later', 'annual_card') then
    perform booking._err('invalid_payment_method', 'Tätä maksutapaa ei käytetä kuittaukseen');
  end if;
  select * into p from booking.payments where id = p_payment_id;
  if not found then perform booking._err('not_found', 'Maksulinkkiä ei löydy'); end if;
  perform 1 from booking.orders where id = p.order_id for update;
  select * into p from booking.payments where id = p_payment_id for update;
  if not booking._plr_is_tracked(p.id) then perform booking._err('link_closed', 'Maksulinkki ei ole enää avoinna'); end if;
  v := booking.admin_record_payment(p.order_id, p_method, p.amount, coalesce(v_note, 'Seurattavat maksut: merkitty hoidetuksi'));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.payments', p_payment_id::text, 'PAYMENT_LINK_HANDLED',
          jsonb_build_object('method', p_method, 'amount', p.amount, 'payment_id', v -> 'payment_id', 'receipt_no', v -> 'receipt_no'));
  return v || jsonb_build_object('handled', true, 'link_payment_id', p_payment_id);
end $$;

-- ---------- claim: muistutuksen payload + linkki pois, jos maksu ei ole enää auki ----------
do $$
begin
  if to_regprocedure('booking.email_outbox_claim_base_215(integer)') is null then
    alter function booking.email_outbox_claim(integer) rename to email_outbox_claim_base_215;
  end if;
end $$;
revoke all on function booking.email_outbox_claim_base_215(integer) from public, anon, authenticated;

create or replace function booking.email_outbox_claim(p_limit integer default 20)
returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(
    case when z.item->>'kind' = 'payment_link_reminder' then
      (case when exists (
          select 1 from booking.email_outbox e
          join booking.payments p on p.id = e.payment_id
          join booking.orders o on o.id = e.order_id
         where e.id = (z.item->>'id')::bigint
           and p.status = 'pending' and p.provider <> 'manual' and p.external_source is null and o.external_source is null
           and (p.link_expires_at is null or p.link_expires_at > now()))
        then z.item
        else z.item || jsonb_build_object('payment', (coalesce(z.item->'payment', '{}'::jsonb) - 'link_url'))
       end)
      || coalesce((select jsonb_build_object('payment_reminder', jsonb_build_object(
            'n', e.payload -> 'reminder_no', 'kind', e.payload ->> 'reminder_kind',
            'cancel_if_unpaid', coalesce((e.payload ->> 'cancel_if_unpaid')::boolean, false),
            'due_at', e.payload -> 'due_at'))
          from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else z.item end
  order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_215(p_limit)) with ordinality as z(item, ord);
$$;

revoke all on function booking._plr_hours(text, integer, integer, integer) from public, anon, authenticated;
revoke all on function booking._plr_enabled() from public, anon, authenticated;
revoke all on function booking._plr_window() from public, anon, authenticated;
revoke all on function booking._plr_in_window(timestamptz) from public, anon, authenticated;
revoke all on function booking._plr_next_open(timestamptz) from public, anon, authenticated;
revoke all on function booking._plr_link_kind(timestamptz, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function booking._plr_is_tracked(bigint, timestamptz) from public, anon, authenticated;
revoke all on function booking._plr_plan(bigint, timestamptz, timestamptz, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function booking._plr_enqueue(bigint, bigint, integer, text, timestamptz, boolean, timestamptz) from public, anon, authenticated;
revoke all on function booking.payment_link_reminders_sweep(timestamptz) from public, anon, authenticated;
revoke all on function booking.payments_reminder_stop_trg() from public, anon, authenticated;
revoke all on function booking.admin_list_payment_link_watch(text, text, integer, integer) from public, anon;
revoke all on function booking.admin_payment_link_remind_now(bigint) from public, anon;
revoke all on function booking.admin_payment_link_pause_reminders(bigint) from public, anon;
revoke all on function booking.admin_payment_link_mark_handled(bigint, text, text) from public, anon;
revoke all on function booking.email_outbox_claim(integer) from public, anon, authenticated;

grant execute on function booking.payment_link_reminders_sweep(timestamptz) to service_role;
grant execute on function booking.email_outbox_claim(integer) to service_role;
grant execute on function booking.admin_list_payment_link_watch(text, text, integer, integer) to authenticated, service_role;
grant execute on function booking.admin_payment_link_remind_now(bigint) to authenticated, service_role;
grant execute on function booking.admin_payment_link_pause_reminders(bigint) to authenticated, service_role;
grant execute on function booking.admin_payment_link_mark_handled(bigint, text, text) to authenticated, service_role;

comment on function booking.payment_link_reminders_sweep(timestamptz) is
  'booking_215: automaattiset maksulinkkimuistutukset. Ei lähetä, jos payment_link.reminders_enabled ei ole true tai kello on ikkunan ulkopuolella. service_role.';
comment on function booking.admin_list_payment_link_watch(text, text, integer, integer) is
  'booking_215: avoimet maksulinkit seurantaan. payments.manage. Ei Montonio-nimeä.';
comment on function booking.admin_payment_link_remind_now(bigint) is
  'booking_215: lähetä seuraava muistutus heti (ohittaa kellonajan ja tauon). payments.manage.';
comment on function booking.admin_payment_link_pause_reminders(bigint) is
  'booking_215: keskeytä automaattiset muistutukset tältä linkiltä. payments.manage.';
comment on function booking.admin_payment_link_mark_handled(bigint, text, text) is
  'booking_215: kirjaa linkin summa käsin (admin_record_payment) ja peruu avoimen linkin. Ei kuittisähköpostia. payments.manage.';

-- Cron vain, jos muistutukset on jo kytketty (uusinta) ja cron-skeema on olemassa. Oletusasetus on false,
-- joten ensimmäinen ajo DEV:ssä ja PROD:ssa ei luo jobia eikä lähetä viestejä.
do $$
begin
  if coalesce(current_setting('booking.skip_cron', true), '') = 'on' then
    raise notice 'booking_215: booking.skip_cron=on, ajastusta ei luoda';
    return;
  end if;
  if not booking._plr_enabled() then
    raise notice 'booking_215: payment_link.reminders_enabled ei ole true, ajastusta ei luoda. Tuotanto: booking/supabase/manual/booking_215_payment_link_reminders_cron.sql';
    return;
  end if;
  if to_regnamespace('cron') is null or to_regprocedure('cron.schedule(text,text,text)') is null then
    raise notice 'booking_215: cron-skeemaa ei ole, ajastusta ei luoda';
    return;
  end if;
  if not exists (select 1 from cron.job where jobname = 'booking_payment_link_reminders') then
    perform cron.schedule('booking_payment_link_reminders', '*/15 * * * *', 'select booking.payment_link_reminders_sweep()');
  end if;
exception when others then
  raise notice 'booking_215: cron-ajastus ohitettu: %', sqlerrm;
end $$;
