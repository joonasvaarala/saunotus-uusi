-- =====================================================================
-- booking 01: skeema, apufunktiot, henkilöstö, asetukset, resurssit
-- Ajetaan Bottiavustuksen kautta (Supabase-projekti Tapio-havuhattu). EI koske public- eikä kb-skeemaan
-- (kb-skeemaan viitataan vain viiteavaimilla ja SECURITY DEFINER -funktioilla myöhemmissä migraatioissa).
-- =====================================================================
set local search_path = booking, extensions, public;

create extension if not exists btree_gist with schema extensions;

create schema if not exists booking;
comment on schema booking is 'Oma varausjärjestelmä (Sipoonjoen perinnesauna). Tuotteet/hinnat: kb-skeema on totuus.';

-- Oikeudet: oletuksena ei mitään (anon/authenticated saavat vain eksplisiittisesti annetut)
alter default privileges in schema booking revoke execute on functions from public;
revoke all on schema booking from public;
grant usage on schema booking to anon, authenticated, service_role;

-- ---------- virhekoodit ----------
-- Liiketoimintavirheet nostetaan SQLSTATE 'BK001'; DETAIL = koneluettava koodi (esim. capacity_exceeded)
create or replace function booking._err(p_code text, p_msg text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  raise exception '%', p_msg using errcode = 'BK001', detail = p_code;
end $$;

-- JWT-rooli (anon / authenticated / service_role); null jos ei JWT:tä (esim. suora tietokantayhteys)
create or replace function booking._jwt_role()
returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
                  nullif(current_setting('request.jwt.claim.role', true), ''))
$$;

-- ---------- updated_at ----------
create or replace function booking.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------- henkilöstö (admin / staff) ----------
create table booking.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text not null,
  role       text not null check (role in ('admin','staff')),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table booking.staff is 'Hallinnan käyttäjät. Vain täällä oleva aktiivinen käyttäjä pääsee hallintaan (auth.uid()).';
create trigger staff_updated before update on booking.staff for each row execute function booking.set_updated_at();

-- Apufunktiot RLS:lle ja funktioille. SECURITY DEFINER, jotta ne näkevät staff-taulun RLS:stä huolimatta.
create or replace function booking.current_staff_role()
returns text language sql stable security definer set search_path = '' as $$
  select s.role from booking.staff s where s.user_id = auth.uid() and s.active
$$;

create or replace function booking.is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(booking.current_staff_role() in ('admin','staff'), false)
$$;

create or replace function booking.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(booking.current_staff_role() = 'admin', false)
$$;

-- Nostaa virheen jos kutsuja ei ole staff/admin (käytetään admin_*-funktioissa)
create or replace function booking._require_staff()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
end $$;
create or replace function booking._require_admin()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not booking.is_admin() then perform booking._err('forbidden', 'Vain ylläpitäjä (admin)'); end if;
end $$;

-- ---------- asetukset (avain → jsonb) ----------
create table booking.settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  is_public   boolean not null default false,   -- näkyy anonille public_settings()-funktion kautta
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
create trigger settings_updated before update on booking.settings for each row execute function booking.set_updated_at();

-- ---------- resurssit ----------
-- space = fyysinen tila / poissulkevuusalue (Savusauna): yksityisvuoro vie koko tilan.
-- capacity_pool = samanaikaisten henkilöiden enimmäismäärä tilassa (esim. 'yleinen_arki' 16, 'yleinen_vkp' 6, 'turve' 8).
-- person = työntekijä (saunottaja), varattu myöhemmin hoitovarauksiin.
create table booking.resources (
  id             bigint generated always as identity primary key,
  code           text not null unique,
  name           text not null,
  kind           text not null check (kind in ('space','capacity_pool','person')),
  parent_id      bigint references booking.resources(id),
  kb_location_id bigint references kb.locations(id),
  capacity       integer check (capacity is null or capacity > 0),
  active         boolean not null default true,
  sort_order     integer not null default 0,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint pool_needs_capacity check (kind <> 'capacity_pool' or (capacity is not null and parent_id is not null))
);
create trigger resources_updated before update on booking.resources for each row execute function booking.set_updated_at();
create index resources_parent_idx on booking.resources(parent_id);

-- ---------- tuotteiden varauskohtainen konfiguraatio (kb.products on totuus nimelle/kuvaukselle/hinnalle) ----------
create table booking.product_config (
  product_id   bigint primary key references kb.products(id),
  sale_kind    text not null check (sale_kind in ('public_shift','private_shift','other')),
  bookable     boolean not null default false,  -- saa varata järjestelmän kautta
  shop_visible boolean not null default true,   -- näkyy kauppapaikassa
  sort_order   integer not null default 100,
  min_persons  integer not null default 1 check (min_persons >= 1),
  max_persons  integer check (max_persons is null or max_persons >= 1),
  notes        text,
  updated_at   timestamptz not null default now()
);
create trigger product_config_updated before update on booking.product_config for each row execute function booking.set_updated_at();

-- ---------- audit-loki ----------
create table booking.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid,                -- auth.uid() (null = järjestelmä / service_role / julkinen varaus)
  actor_role text,                -- jwt-rooli: anon / authenticated / service_role
  table_name text not null,
  row_pk     text,
  action     text not null,       -- INSERT / UPDATE / DELETE / jokin funktion oma toiminto
  old_data   jsonb,
  new_data   jsonb
);
create index audit_log_table_idx on booking.audit_log(table_name, row_pk, at desc);
create index audit_log_at_idx on booking.audit_log(at desc);

create or replace function booking.audit_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  o jsonb; n jsonb; pk text;
begin
  if tg_op in ('UPDATE','DELETE') then o := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then n := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and o = n then return null; end if;
  pk := coalesce(n ->> 'id', n ->> 'key', n ->> 'user_id', n ->> 'product_id',
                 o ->> 'id', o ->> 'key', o ->> 'user_id', o ->> 'product_id');
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), tg_table_name, pk, tg_op, o, n);
  return null;
end $$;

-- Apufunktio: lisää audit-trigger tauluun
create or replace function booking._add_audit(p_table regclass)
returns void language plpgsql set search_path = '' as $$
begin
  execute format('create trigger audit_trg after insert or update or delete on %s for each row execute function booking.audit_trg()', p_table);
end $$;

do $$ begin
  perform booking._add_audit('booking.staff');
  perform booking._add_audit('booking.settings');
  perform booking._add_audit('booking.resources');
  perform booking._add_audit('booking.product_config');
end $$;
