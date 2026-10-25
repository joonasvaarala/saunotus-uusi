-- HISTORY-SYNC: tämä migraatio on jo ajettu tuotannossa (Supabase sxbofnuisemspgquoxyv) 25.10.2026, versio 20261025130308 (backlog_categories_v2).
-- Lisätty repoon jälkikäteen; lauseet sellaisenaan tuotannon migraatiohistoriasta (identtinen /workspace/backlog_v2/migration_backlog_categories_v2.sql,
-- md5 a6603b9b8df493a6be41bb6f21a75617). EI AJETA UUDELLEEN TUOTANTOON (ei idempotentti: create table / insert / update).
-- Riippuvuudet, joita tämä repon ketju EI luo: skeema kb ja kb.feature_backlog (tuotannossa migraatio 20261022165409 kb_feature_backlog), public.staff.
-- Migration: backlog_categories_v2  (2026-10-25, approved by Joonas)
-- Restructures kb.feature_backlog into a categorised to-do list with kinds, sub-tasks,
-- timestamped notes and owners. Additive: no existing column is dropped or rewritten
-- except `position` (renumbered per category; old value kept in position_legacy).

-- 1. Categories lookup -------------------------------------------------------
create table kb.backlog_categories (
  key     text primary key,
  name_fi text not null,
  sort    integer not null unique
);
comment on table kb.backlog_categories is 'Categories of Joonas''s to-do list (kb.feature_backlog.category).';
insert into kb.backlog_categories (key, name_fi, sort) values
  ('sivusto_fiksaus',  'Sivuston fiksaukset',   1),
  ('sivusto_projekti', 'Sivuston projektit',    2),
  ('sauna_fiksaus',    'Saunan fiksaukset',     3),
  ('sauna_projekti',   'Saunan projektit',      4),
  ('paatettava',       'Päätettävät asiat',     5),
  ('hallinto',         'Hallinto ja talous',    6);

-- 2. New columns on items ------------------------------------------------------
alter table kb.feature_backlog
  add column category        text references kb.backlog_categories(key) on update cascade,
  add column kind            text not null default 'fix',
  add column due_date        date,
  add column done_at         timestamptz,
  add column position_legacy integer;
alter table kb.feature_backlog
  add constraint feature_backlog_kind_check check (kind in ('fix','project'));

comment on column kb.feature_backlog.category is 'FK kb.backlog_categories.key. NULL = not yet categorised.';
comment on column kb.feature_backlog.kind is 'fix = single job, project = has sub-tasks in kb.backlog_tasks.';
comment on column kb.feature_backlog.position is 'Order WITHIN category (since backlog_categories_v2).';
comment on column kb.feature_backlog.position_legacy is 'Global position before backlog_categories_v2 (2026-10-25).';
comment on column kb.feature_backlog.due_date is 'Optional deadline (supersedes target_date; copied from it 2026-10-25).';
comment on column kb.feature_backlog.target_date is 'LEGACY: superseded by due_date (2026-10-25).';
comment on column kb.feature_backlog.notes is 'LEGACY: frozen 2026-10-25, content copied to kb.backlog_notes (kind background). Add new notes to kb.backlog_notes.';
comment on column kb.feature_backlog.owner_bot is 'LEGACY: owners now in kb.backlog_owners (copied 2026-10-25).';
comment on column kb.feature_backlog.status is 'queued | in_progress | waiting (odottaa jotakuta) | done (archived, done_at set).';

-- 3. Status normalisation ------------------------------------------------------
-- Existing values in production: queued, in_progress, done only (approved/cancelled/on_hold unused).
alter table kb.feature_backlog drop constraint feature_backlog_status_check;
update kb.feature_backlog set status = 'queued'  where status = 'approved';
update kb.feature_backlog set status = 'waiting' where status = 'on_hold';
update kb.feature_backlog set status = 'done'    where status = 'cancelled';
alter table kb.feature_backlog
  add constraint feature_backlog_status_check
  check (status in ('queued','in_progress','waiting','done'));

update kb.feature_backlog
   set done_at = coalesce(done_at, updated_at)
 where status = 'done';

update kb.feature_backlog set due_date = target_date where target_date is not null;

-- 4. Classification of existing rows (by id, reviewed manually 2026-10-25) ----
with m(id, category, kind) as (values
  -- sivuston fiksaukset
  ( 2,'sivusto_fiksaus','fix'),( 3,'sivusto_fiksaus','fix'),( 4,'sivusto_fiksaus','fix'),
  ( 5,'sivusto_fiksaus','fix'),(46,'sivusto_fiksaus','fix'),( 6,'sivusto_fiksaus','fix'),
  (17,'sivusto_fiksaus','fix'),(25,'sivusto_fiksaus','fix'),(29,'sivusto_fiksaus','fix'),
  (41,'sivusto_fiksaus','fix'),(44,'sivusto_fiksaus','fix'),
  -- sivuston projektit
  ( 1,'sivusto_projekti','project'),(19,'sivusto_projekti','project'),(21,'sivusto_projekti','project'),
  ( 7,'sivusto_projekti','project'),( 8,'sivusto_projekti','project'),( 9,'sivusto_projekti','project'),
  (10,'sivusto_projekti','project'),(20,'sivusto_projekti','project'),(48,'sivusto_projekti','project'),
  (11,'sivusto_projekti','project'),(12,'sivusto_projekti','project'),(13,'sivusto_projekti','project'),
  (14,'sivusto_projekti','project'),(15,'sivusto_projekti','project'),(16,'sivusto_projekti','project'),
  (18,'sivusto_projekti','project'),(30,'sivusto_projekti','project'),(47,'sivusto_projekti','project'),
  -- saunan fiksaukset
  (42,'sauna_fiksaus','fix'),
  -- päätettävät asiat
  (22,'paatettava','fix'),(23,'paatettava','fix'),(24,'paatettava','fix'),(26,'paatettava','fix'),
  (27,'paatettava','fix'),(28,'paatettava','fix'),(31,'paatettava','fix'),(32,'paatettava','fix'),
  (33,'paatettava','fix'),(34,'paatettava','fix'),(35,'paatettava','fix'),(36,'paatettava','fix'),
  (37,'paatettava','fix'),(38,'paatettava','fix'),(45,'paatettava','fix'),
  -- hallinto ja talous
  (39,'hallinto','fix'),(40,'hallinto','fix'),(43,'hallinto','fix')
)
update kb.feature_backlog f
   set category = m.category, kind = m.kind
  from m
 where f.id = m.id;

-- 5. Position per category (keeps previous relative order) -------------------
update kb.feature_backlog set position_legacy = position;
with r as (
  select id, row_number() over (partition by category order by position_legacy, id) as rn
    from kb.feature_backlog
)
update kb.feature_backlog f set position = r.rn from r where f.id = r.id;

create index feature_backlog_category_position_idx
  on kb.feature_backlog (category, position) where status <> 'done';

-- done_at maintenance
create function kb.feature_backlog_done_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'done' then
    if tg_op = 'INSERT' or old.status is distinct from 'done' then
      new.done_at := coalesce(new.done_at, now());
    end if;
  elsif tg_op = 'UPDATE' and old.status = 'done' then
    new.done_at := null;
  end if;
  return new;
end $$;
create trigger feature_backlog_done_at
  before insert or update of status on kb.feature_backlog
  for each row execute function kb.feature_backlog_done_at();

-- 6. Sub-tasks -----------------------------------------------------------------
create table kb.backlog_tasks (
  id         bigint generated always as identity primary key,
  item_id    bigint not null references kb.feature_backlog(id) on delete cascade,
  title      text not null,
  done       boolean not null default false,
  done_at    timestamptz,
  position   integer not null default 0,
  owner      text,
  due_date   date,
  created_at timestamptz not null default now(),
  constraint backlog_tasks_id_item_key unique (id, item_id)
);
create index backlog_tasks_item_idx on kb.backlog_tasks (item_id, position);
comment on table kb.backlog_tasks is 'Sub-tasks of project items in kb.feature_backlog.';

create function kb.backlog_tasks_done_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.done then
    if tg_op = 'INSERT' or not old.done then new.done_at := coalesce(new.done_at, now()); end if;
  else
    new.done_at := null;
  end if;
  return new;
end $$;
create trigger backlog_tasks_done_at
  before insert or update of done on kb.backlog_tasks
  for each row execute function kb.backlog_tasks_done_at();

-- 7. Notes / background / links ------------------------------------------------
create table kb.backlog_notes (
  id         bigint generated always as identity primary key,
  item_id    bigint not null references kb.feature_backlog(id) on delete cascade,
  task_id    bigint,
  kind       text not null default 'note' check (kind in ('note','link','background')),
  body       text not null,
  url        text,
  created_at timestamptz not null default now(),
  created_by text not null default current_user,
  constraint backlog_notes_task_fkey foreign key (task_id, item_id)
    references kb.backlog_tasks (id, item_id) on delete cascade
);
create index backlog_notes_item_idx on kb.backlog_notes (item_id, created_at);
create index backlog_notes_task_idx on kb.backlog_notes (task_id) where task_id is not null;
comment on table kb.backlog_notes is 'Timestamped notes, background and links per backlog item (optionally per task).';

insert into kb.backlog_notes (item_id, kind, body, created_at, created_by)
select id, 'background', notes, created_at, 'migration backlog_categories_v2'
  from kb.feature_backlog
 where nullif(btrim(notes), '') is not null;

-- 8. Owners --------------------------------------------------------------------
create table kb.backlog_owners (
  item_id    bigint not null references kb.feature_backlog(id) on delete cascade,
  owner_key  text not null,
  owner_type text not null check (owner_type in ('staff','bot','joonas')),
  staff_id   uuid references public.staff(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (item_id, owner_key),
  constraint backlog_owners_staff_check check (
    (owner_type <> 'staff' or (staff_id is not null and owner_key = staff_id::text))
    and (owner_type <> 'bot' or staff_id is null)
  )
);
create index backlog_owners_owner_idx on kb.backlog_owners (owner_key);
comment on table kb.backlog_owners is
  'Owners per item. owner_key: staff -> public.staff.id as text; bot -> lowercase bot name (e.g. koodari); joonas -> ''joonas''.';

insert into kb.backlog_owners (item_id, owner_key, owner_type)
select id,
       lower(btrim(owner_bot)),
       case when lower(btrim(owner_bot)) = 'joonas' then 'joonas' else 'bot' end
  from kb.feature_backlog
 where nullif(btrim(owner_bot), '') is not null;

-- 9. Tasks for project "Siirto 1.11." (id 30) from its checklist ----------------
insert into kb.backlog_tasks (item_id, title, position, due_date)
select 30, t.title, t.pos, t.due
  from (values
    ( 1, 'Nimetään vastuuhenkilö jokaiselle siirron vaiheelle', date '2026-10-31'),
    ( 2, 'Ennen 31.10.: Supabase Pro ja varmuuskopio',          date '2026-10-30'),
    ( 3, 'Ennen 31.10.: testidata pois tuotannosta',             date '2026-10-30'),
    ( 4, 'Ennen 31.10.: MobilePay live',                         date '2026-10-30'),
    ( 5, 'Ennen 31.10.: tekstit hyväksytty',                     date '2026-10-30'),
    ( 6, 'La 31.10. ennen klo 24: viimeinen Johku-synkka',       date '2026-10-31'),
    ( 7, 'La 31.10.: lahjakorttisaldot täsmäytetty',             date '2026-10-31'),
    ( 8, 'La 31.10.: Johkun kortit suljettu',                    date '2026-10-31'),
    ( 9, 'Su 1.11. klo 0: Johku kiinni',                         date '2026-11-01'),
    (10, 'Su 1.11. klo 8–11: siirto, testivaraus, lahjakortin lunastus, vahvistusviesti, kalenterit', date '2026-11-01'),
    (11, 'Varasuunnitelma valmiina: ilmoitus sivulla ja varaukset puhelimitse', date '2026-10-31')
  ) as t(pos, title, due)
 where exists (select 1 from kb.feature_backlog where id = 30 and title like 'Siirto 1.11.%');

-- 10. RLS + grants (mirrors kb.feature_backlog: authenticated read-only, service_role writes)
alter table kb.backlog_categories enable row level security;
alter table kb.backlog_tasks      enable row level security;
alter table kb.backlog_notes      enable row level security;
alter table kb.backlog_owners     enable row level security;
create policy backlog_categories_read on kb.backlog_categories for select to authenticated using (true);
create policy backlog_tasks_read      on kb.backlog_tasks      for select to authenticated using (true);
create policy backlog_notes_read      on kb.backlog_notes      for select to authenticated using (true);
create policy backlog_owners_read     on kb.backlog_owners     for select to authenticated using (true);

revoke all on kb.backlog_categories, kb.backlog_tasks, kb.backlog_notes, kb.backlog_owners from anon, authenticated;
grant select on kb.backlog_categories, kb.backlog_tasks, kb.backlog_notes, kb.backlog_owners to authenticated;
grant select on kb.backlog_categories to service_role;
grant select, insert, update, delete on kb.backlog_tasks, kb.backlog_owners to service_role;
grant select, insert, update on kb.backlog_notes to service_role;
grant select on kb.backlog_categories, kb.backlog_tasks, kb.backlog_notes, kb.backlog_owners to backup_reader;

-- 11. Read helpers (SECURITY INVOKER; caller's RLS/grants apply) ---------------
create view kb.backlog_overview with (security_invoker = true) as
select i.id, i.category, c.name_fi as category_name, c.sort as category_sort,
       i.position, i.kind, i.status, i.title, i.description, i.due_date,
       i.needs_approval, i.done_at, i.created_at, i.updated_at,
       coalesce((select jsonb_agg(jsonb_build_object('owner_key', o.owner_key, 'owner_type', o.owner_type,
                                                     'name', s.name) order by o.created_at, o.owner_key)
                   from kb.backlog_owners o left join public.staff s on s.id = o.staff_id
                  where o.item_id = i.id), '[]'::jsonb) as owners,
       (select count(*) from kb.backlog_tasks t where t.item_id = i.id)            as tasks_total,
       (select count(*) from kb.backlog_tasks t where t.item_id = i.id and t.done) as tasks_done
  from kb.feature_backlog i
  left join kb.backlog_categories c on c.key = i.category;
revoke all on kb.backlog_overview from anon, authenticated;
grant select on kb.backlog_overview to authenticated, service_role, backup_reader;

create function kb.backlog_for_owner(p_owner_key text, p_include_done boolean default false)
returns table (
  id bigint, category text, category_name text, category_sort integer, "position" integer,
  kind text, status text, title text, description text, due_date date, needs_approval boolean,
  owners jsonb, tasks jsonb
)
language sql stable security invoker set search_path = '' as $$
  select v.id, v.category, v.category_name, v.category_sort, v.position,
         v.kind, v.status, v.title, v.description, v.due_date, v.needs_approval,
         v.owners,
         coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'done', t.done,
                                                       'done_at', t.done_at, 'owner', t.owner,
                                                       'due_date', t.due_date, 'position', t.position)
                                    order by t.position, t.id)
                     from kb.backlog_tasks t where t.item_id = v.id), '[]'::jsonb)
    from kb.backlog_overview v
   where (p_include_done or v.status <> 'done')
     and (   not exists (select 1 from kb.backlog_owners o where o.item_id = v.id)
          or exists (select 1 from kb.backlog_owners o where o.item_id = v.id and o.owner_key = p_owner_key))
   order by v.category_sort nulls last, v.position, v.id
$$;
comment on function kb.backlog_for_owner(text, boolean) is
  'Items with no owner OR owned by p_owner_key (+ their tasks). SECURITY INVOKER groundwork for Otto''s bot; no new roles/grants yet.';
revoke all on function kb.backlog_for_owner(text, boolean) from public, anon;
grant execute on function kb.backlog_for_owner(text, boolean) to authenticated, service_role;
revoke all on function kb.feature_backlog_done_at(), kb.backlog_tasks_done_at() from public, anon, authenticated;

-- 12. Safety assertions ----------------------------------------------------------
do $$
declare n_uncat int; n_notes_src int; n_notes int; n_own_src int; n_own int;
begin
  select count(*) into n_uncat from kb.feature_backlog where category is null;
  if n_uncat > 0 then raise exception 'backlog_categories_v2: % rows uncategorised', n_uncat; end if;
  select count(*) into n_notes_src from kb.feature_backlog where nullif(btrim(notes),'') is not null;
  select count(*) into n_notes from kb.backlog_notes where created_by = 'migration backlog_categories_v2';
  if n_notes <> n_notes_src then raise exception 'notes copy mismatch % vs %', n_notes, n_notes_src; end if;
  select count(*) into n_own_src from kb.feature_backlog where nullif(btrim(owner_bot),'') is not null;
  select count(*) into n_own from kb.backlog_owners;
  if n_own <> n_own_src then raise exception 'owners copy mismatch % vs %', n_own, n_own_src; end if;
end $$;
