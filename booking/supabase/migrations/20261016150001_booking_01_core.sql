-- =====================================================================
-- booking 01: skeema, apufunktiot, roolit ja oikeudet, henkilöstö, asetukset, resurssit
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

-- ---------- roolit ja oikeudet (taulupohjaiset, helposti laajennettavat) ----------
-- Roolit ovat DATAA: uusi rooli = uusi rivi tauluun booking.roles (+ oikeudet riveinä tauluun booking.role_permissions).
-- Ei enum-tyyppiä eikä kovakoodattua rooliluetteloa funktioissa: funktiot kysyvät OIKEUKSIA (has_permission), eivät rooleja.
--   is_staff = true  → henkilöstörooli (admin / manager / staff): voi saada rivin booking.staff ja pääsee hallintaan
--   is_staff = false → ei-henkilöstörooli (customer / annual_card): EI oikeuksia hallintaan; käytetään asiakkaan tyyppinä
--                      (booking.customers.customer_type)
-- Uuden roolin lisääminen: ks. README "Roolit" / docs/roolit-ja-kb.md.
create table booking.roles (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  label       text not null,
  description text,
  is_staff    boolean not null,
  sort_order  integer not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (code, is_staff)                          -- tarvitaan yhdistelmäavaimelle (staff.role / customers.customer_type)
);
comment on table booking.roles is 'Roolit (taulupohjainen, ei enumia). is_staff=false: asiakasroolit ilman hallintaoikeuksia.';

-- Oikeuskoodit (hallinnan toiminnot). Funktiot tarkistavat oikeuden, eivät roolinimeä.
create table booking.role_permissions (
  role_code  text not null references booking.roles(code) on delete cascade,
  permission text not null check (permission ~ '^[a-z_]+\.[a-z_]+$'),
  primary key (role_code, permission)
);
comment on table booking.role_permissions is
  'Rooli → oikeus. Oikeudet: bookings.manage, customers.manage, payments.manage, blocks.manage, catalog.edit (tuotteet/hinnat/kuvaukset), '
  'settings.edit, resources.edit (kapasiteettipoolit), rules.edit (vuorosäännöt), annual_cards.manage, staff.manage, audit.read.';

insert into booking.roles(code, label, description, is_staff, sort_order) values
  ('admin',       'Pääkäyttäjä (admin)',   'Kaikki oikeudet, myös henkilöstön ja roolien hallinta',                                 true,  10),
  ('manager',     'Ylläpitäjä (manager)', 'Varaukset + hinnat, kuvaukset, tuoteasetukset, asetukset, resurssit ja vuorosäännöt; ei henkilöstön hallintaa', true, 20),
  ('staff',       'Peruskäyttäjä (staff)','Näkee ja luo/muokkaa varauksia ja asiakkaita; ei hinnan/tuotteen/asetusten muokkausta',  true,  30),
  ('customer',    'Asiakas',              'Tavallinen asiakas. Ei oikeuksia hallintaan (asiakkaan oma kirjautuminen tulee myöhemmin)', false, 100),
  ('annual_card', 'Vuosikorttiasiakas',   'Voi tehdä ilmaisia varauksia yleisille vuoroille (yksi tuleva varaus kerrallaan)',      false, 110);

insert into booking.role_permissions(role_code, permission)
select r.code, p.permission
  from (values
    ('admin','bookings.manage'),('admin','customers.manage'),('admin','payments.manage'),('admin','blocks.manage'),
    ('admin','catalog.edit'),('admin','settings.edit'),('admin','resources.edit'),('admin','rules.edit'),
    ('admin','annual_cards.manage'),('admin','staff.manage'),('admin','audit.read'),
    ('manager','bookings.manage'),('manager','customers.manage'),('manager','payments.manage'),('manager','blocks.manage'),
    ('manager','catalog.edit'),('manager','settings.edit'),('manager','resources.edit'),('manager','rules.edit'),
    ('manager','annual_cards.manage'),
    ('staff','bookings.manage'),('staff','customers.manage'),('staff','payments.manage'),('staff','blocks.manage')
  ) as p(role_code, permission)
  join booking.roles r on r.code = p.role_code;

-- ---------- henkilöstö (hallinnan käyttäjät) ----------
-- role viittaa roles-tauluun; generoitu role_is_staff=true + yhdistelmäavain estää ei-henkilöstöroolien (customer, annual_card) käytön tässä.
create table booking.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text not null,
  role       text not null,
  role_is_staff boolean not null generated always as (true) stored,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_role_fk foreign key (role, role_is_staff) references booking.roles(code, is_staff)
);
comment on table booking.staff is 'Hallinnan käyttäjät. Vain täällä oleva aktiivinen käyttäjä pääsee hallintaan (auth.uid()). role → booking.roles (is_staff=true).';
create trigger staff_updated before update on booking.staff for each row execute function booking.set_updated_at();

-- Apufunktiot RLS:lle ja funktioille. SECURITY DEFINER, jotta ne näkevät staff-taulun RLS:stä huolimatta.
create or replace function booking.current_staff_role()
returns text language sql stable security definer set search_path = '' as $$
  select s.role from booking.staff s join booking.roles r on r.code = s.role and r.active and r.is_staff
   where s.user_id = auth.uid() and s.active
$$;

create or replace function booking.is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select booking.current_staff_role() is not null
$$;

-- Onko kirjautuneella käyttäjällä oikeus (rooli → role_permissions). Kaikki hallinnan tarkistukset kulkevat tämän kautta.
create or replace function booking.has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from booking.role_permissions rp
                  where rp.role_code = booking.current_staff_role() and rp.permission = p_permission)
$$;

-- admin = rooli 'admin' (säilytetty yhteensopivuuden vuoksi; uusi koodi käyttää has_permission)
create or replace function booking.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(booking.current_staff_role() = 'admin', false)
$$;

-- Nostaa virheen jos kutsuja ei ole henkilöstöä (käytetään admin_*-funktioissa)
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
-- Vaatii nimetyn oikeuden. Ei-henkilöstö saa "Ei oikeuksia", henkilöstö ilman oikeutta "Ei oikeutta tähän toimintoon (<oikeus>)".
create or replace function booking._require_permission(p_permission text)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if not booking.has_permission(p_permission) then
    perform booking._err('forbidden', 'Ei oikeutta tähän toimintoon (' || p_permission || ')');
  end if;
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
-- capacity_pool = henkilöiden enimmäismäärä (esim. 'yleinen_arki' 16, 'turve' 8; viikonloppuna oma pooli per aloitusaika: 'yleinen_vkp_1400' 6 …).
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
  pk := coalesce(n ->> 'id', n ->> 'key', n ->> 'user_id', n ->> 'product_id', n ->> 'code',
                 o ->> 'id', o ->> 'key', o ->> 'user_id', o ->> 'product_id', o ->> 'code');
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
  perform booking._add_audit('booking.roles');
  perform booking._add_audit('booking.role_permissions');
  perform booking._add_audit('booking.staff');
  perform booking._add_audit('booking.settings');
  perform booking._add_audit('booking.resources');
  perform booking._add_audit('booking.product_config');
end $$;
