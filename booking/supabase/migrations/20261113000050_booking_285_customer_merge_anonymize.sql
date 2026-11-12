-- booking_285 (Tilausnäkymä v3, PR 4): asiakkaiden yhdistäminen ja anonymisointi. EI AJETA tästä haarasta: Bottiavustus ajaa DEV → PROD.
-- Määrittely: toteutusmaarittely.md §1.4, §4 rivi I, §5, §6, §7, §8/4. Rollback: booking/supabase/rollbacks/20261113000050_booking_285_ROLLBACK.sql
--
-- Sisältö
--  1. Oikeus customers.admin (admin + manager). Palvelin tarkistaa joka funktiossa (_require_permission).
--  2. Kytkimet booking.settings: customer_merge_enabled = false, customer_anonymize_enabled = false.
--     KYTKIMIÄ EI KYTKETÄ PÄÄLLE TÄSSÄ MIGRAATIOSSA EIKÄ MISSÄÄN MUUALLA. Anonymisointi vaatii Joonaksen erillisen luvan (backlog #45).
--  3. customers.merged_into / merged_at (yhdistetty rivi säilyy "hautakivenä", jolloin viittaukset eivät katkea ja yhdistäminen on idempotentti).
--  4. booking.customer_merge_log (yksi rivi per yhdistetty asiakas; snapshot + siirretyt rivit) ja
--     booking.marketing_suppressions (sähköpostiosoitteen sha256-tiiviste: uutiskirjeen suppression säilyy, vaikka osoite poistuu asiakasriviltä)
--     + booking.is_email_suppressed(text).
--  5. admin_customer_admin_status(), admin_merge_customers_preview(p_keep, p_merge), admin_merge_customers(p_keep, p_merge, p_confirm, p_reason),
--     admin_anonymize_customer_preview(p_id), admin_anonymize_customer(p_id, p_reason, p_confirm).
--
-- Ei muuteta yhtään olemassa olevaa funktiota (ei booking_287/288:n funktioita, ei peruutus- tai maksulinkkilogiikkaa).
-- Yhdistäminen siirtää KAIKKI viittaukset booking.customers(id):hen dynaamisesti (pg_constraint), joten myös taulut, joita tämä
-- repo ei näe (esim. PRODin booking_259/262 -uutiskirjetaulut, jos niillä on FK asiakkaaseen), kulkevat mukana. Sähköpostiavaimisia
-- suppression-/consent-tauluja EI koskaan muuteta eikä poisteta.
set local search_path = booking, extensions, public;
set local lock_timeout = '5s';

-- ---------- 1) oikeus ----------
insert into booking.role_permissions(role_code, permission) values ('admin', 'customers.admin'), ('manager', 'customers.admin')
on conflict do nothing;
comment on table booking.role_permissions is
  'Rooli → oikeus. Oikeudet: bookings.manage, customers.manage, customers.admin (asiakkaiden yhdistäminen ja anonymisointi; admin + manager), payments.manage, blocks.manage, catalog.edit (tuotteet/hinnat/kuvaukset), '
  'settings.edit, resources.edit (kapasiteettipoolit), rules.edit (vuorosäännöt), annual_cards.manage, staff.manage (käyttäjä- ja roolihallinta, vain admin), audit.read, '
  'shifts.view (omat työvuorot), shifts.view_all (kaikkien työvuorot; lukunäkymä public-skeeman vuorodataan).';

-- ---------- 2) kytkimet (oletus POIS) ----------
insert into booking.settings(key, value, description, is_public) values
  ('customer_merge_enabled', 'false'::jsonb, 'booking_285: asiakkaiden yhdistäminen hallinnassa (admin_merge_customers). Oletus false. Vaatii lisäksi oikeuden customers.admin.', false),
  ('customer_anonymize_enabled', 'false'::jsonb, 'booking_285: asiakkaan anonymisointi hallinnassa (admin_anonymize_customer). Oletus false. Käyttöönotto vaatii Joonaksen erillisen luvan (backlog #45 Anonymisoinnin käyttöönotto).', false)
on conflict (key) do nothing;

-- ---------- 3) yhdistetyn asiakkaan merkintä ----------
alter table booking.customers
  add column if not exists merged_into bigint references booking.customers(id),
  add column if not exists merged_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'customers_merged_not_self' and conrelid = 'booking.customers'::regclass) then
    alter table booking.customers add constraint customers_merged_not_self check (merged_into is null or merged_into <> id);
  end if;
end $$;
create index if not exists customers_merged_into_idx on booking.customers(merged_into) where merged_into is not null;
comment on column booking.customers.merged_into is 'booking_285: asiakas, johon tämä rivi on yhdistetty. Rivi on anonymized_at-merkitty hautakivi (ei henkilötietoja); tilaukset ym. on siirretty.';

-- ---------- 4) yhdistämisloki ja suppression ----------
create table if not exists booking.customer_merge_log (
  id             bigint generated always as identity primary key,
  keep_id        bigint not null references booking.customers(id),
  merge_id       bigint not null unique references booking.customers(id),   -- asiakas voidaan yhdistää vain kerran → idempotenssin ankkuri
  at             timestamptz not null default now(),
  actor          uuid,
  actor_role     text,
  reason         text,
  merge_snapshot jsonb,            -- yhdistetyn rivin sisältö ennen yhdistämistä (käsin palautusta varten). Tyhjennetään, jos keep-asiakas anonymisoidaan.
  moved          jsonb not null default '{}'::jsonb,   -- {taulu: {moved, left, ids[]}}
  counts         jsonb not null default '{}'::jsonb,
  warnings       jsonb not null default '[]'::jsonb,
  constraint customer_merge_log_distinct check (keep_id <> merge_id)
);
create index if not exists customer_merge_log_keep_idx on booking.customer_merge_log(keep_id);
alter table booking.customer_merge_log enable row level security;
revoke all on booking.customer_merge_log from public, anon, authenticated;
grant select, insert, update on booking.customer_merge_log to service_role;
comment on table booking.customer_merge_log is 'booking_285: asiakkaiden yhdistämisloki. Luku vain funktioiden ja service_rolen kautta (snapshot sisältää henkilötietoja).';

create table if not exists booking.marketing_suppressions (
  email_hash  text primary key check (email_hash ~ '^[0-9a-f]{64}$'),   -- sha256(lower(btrim(email))); itse osoitetta ei säilytetä
  reason      text not null check (reason in ('unsubscribed', 'anonymized', 'merged_unsubscribed')),
  source      text,
  customer_id bigint,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
alter table booking.marketing_suppressions enable row level security;
revoke all on booking.marketing_suppressions from public, anon, authenticated;
grant select, insert on booking.marketing_suppressions to service_role;
comment on table booking.marketing_suppressions is 'booking_285: osoitteet, joille ei lähetetä markkinointia, vaikka asiakasrivi on anonymisoitu tai yhdistetty. Vain tiiviste. Tarkistus: booking.is_email_suppressed(email).';

create or replace function booking._email_hash(p_email text) returns text
language sql immutable set search_path = '' as $$
  select case when nullif(btrim(coalesce(p_email, '')), '') is null then null
              else encode(sha256(convert_to(lower(btrim(p_email)), 'UTF8')), 'hex') end
$$;
revoke all on function booking._email_hash(text) from public, anon, authenticated;

create or replace function booking.is_email_suppressed(p_email text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from booking.marketing_suppressions s where s.email_hash = booking._email_hash(p_email))
$$;
revoke all on function booking.is_email_suppressed(text) from public, anon;
grant execute on function booking.is_email_suppressed(text) to authenticated, service_role;

-- ---------- 5) apufunktiot (sisäiset, ei kutsuttavissa suoraan) ----------
create or replace function booking._customer_flag(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.value = 'true'::jsonb from booking.settings s where s.key = p_key), false)
$$;
revoke all on function booking._customer_flag(text) from public, anon, authenticated;

-- Kaikki yksisarakkeiset viittaukset booking.customers(id):hen (orders ensin; ei customers.merged_into eikä customer_merge_log). Löytää myös taulut, joita tämä repo ei tunne.
create or replace function booking._customer_ref_tables()
returns table(tbl text, col text, has_id boolean)
language sql stable security definer set search_path = '' as $$
  select c.conrelid::regclass::text, a.attname::text,
         exists (select 1 from pg_attribute x where x.attrelid = c.conrelid and x.attname = 'id' and x.attnum > 0 and not x.attisdropped)
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.contype = 'f' and c.confrelid = 'booking.customers'::regclass and cardinality(c.conkey) = 1 and c.conrelid <> c.confrelid
     and c.conrelid <> 'booking.customer_merge_log'::regclass   -- yhdistämisloki on historiaa, ei siirrettävää dataa
   order by (c.conrelid = 'booking.orders'::regclass) desc, c.conrelid::regclass::text, a.attname
$$;
revoke all on function booking._customer_ref_tables() from public, anon, authenticated;

-- Siirtää viittaukset rivi kerrallaan. Rivi, jonka siirto rikkoisi uniikki- tai poissulkuehdon (esim. sama kampanja kahdesti), jää
-- hautakiven riville ("left"). Idempotentti: jo siirretyt eivät enää täsmää.
create or replace function booking._customer_move_refs(p_from bigint, p_to bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; t record; v_moved bigint; v_left bigint; v_ids text[]; v_out jsonb := '{}'::jsonb;
begin
  for r in select * from booking._customer_ref_tables() loop
    v_moved := 0; v_left := 0; v_ids := '{}';
    for t in execute format('select ctid as tid, %s as rid from %s where %I = $1 order by 1',
                            case when r.has_id then 'id::text' else 'null::text' end, r.tbl, r.col) using p_from loop
      begin
        execute format('update %s set %I = $1 where ctid = $2', r.tbl, r.col) using p_to, t.tid;
        v_moved := v_moved + 1;
        if t.rid is not null then v_ids := v_ids || t.rid; end if;
      exception when unique_violation or exclusion_violation then
        v_left := v_left + 1;
      end;
    end loop;
    if v_moved + v_left > 0 then
      v_out := v_out || jsonb_build_object(split_part(r.tbl, '.', 2),
        jsonb_build_object('moved', v_moved, 'left', v_left, 'ids', to_jsonb(v_ids)));
    end if;
  end loop;
  return v_out;
end $$;
revoke all on function booking._customer_move_refs(bigint, bigint) from public, anon, authenticated;

-- ---------- 6) yhdistämissuunnitelma (esikatselu) ----------
create or replace function booking._customer_merge_plan(p_keep bigint, p_merge bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  k booking.customers; m booking.customers;
  v_block jsonb := '[]'::jsonb; v_warn jsonb := '[]'::jsonb; v_counts jsonb := '{}'::jsonb;
  v_already boolean := false; v_n bigint; r record; v_trg text;
  v_same_email boolean; v_m_unsub boolean; v_consent jsonb; v_johku text := 'none'; v_fill text[] := '{}'; f text;
begin
  if p_keep is null or p_merge is null then perform booking._err('invalid_argument', 'Asiakkaan tunniste puuttuu'); end if;
  if p_keep = p_merge then perform booking._err('same_customer', 'Asiakasta ei voi yhdistää itseensä'); end if;
  select * into k from booking.customers where id = p_keep;
  if not found then perform booking._err('not_found', 'Säilytettävää asiakasta ei löydy'); end if;
  select * into m from booking.customers where id = p_merge;
  if not found then perform booking._err('not_found', 'Yhdistettävää asiakasta ei löydy'); end if;

  if m.merged_into = k.id then v_already := true;
  elsif m.merged_into is not null then v_block := v_block || '["merged_into_other"]'::jsonb;
  elsif m.anonymized_at is not null then v_block := v_block || '["merge_anonymized"]'::jsonb; end if;
  if k.anonymized_at is not null or k.merged_into is not null then v_block := v_block || '["keep_anonymized"]'::jsonb; end if;
  if not v_already then
    if k.customer_kind is distinct from m.customer_kind then v_block := v_block || '["kind_mismatch"]'::jsonb; end if;
    if k.auth_user_id is not null and m.auth_user_id is not null then v_block := v_block || '["both_have_login"]'::jsonb; end if;
    if exists (select 1 from booking.annual_cards a join booking.annual_cards b
                 on a.customer_id = k.id and b.customer_id = m.id and a.active and b.active
                and daterange(a.valid_from, a.valid_to, '[]') && daterange(b.valid_from, b.valid_to, '[]')) then
      v_block := v_block || '["annual_card_overlap"]'::jsonb;
    end if;
  end if;

  for r in select * from booking._customer_ref_tables() loop
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into v_n using m.id;
    if v_n > 0 then v_counts := v_counts || jsonb_build_object(split_part(r.tbl, '.', 2), v_n); end if;
  end loop;

  -- suostumus: peruutus voittaa; suostumus periytyy vain samalle osoitteelle
  v_same_email := nullif(btrim(coalesce(k.email, '')), '') is not null and lower(btrim(k.email)) = lower(btrim(coalesce(m.email, '')));
  v_m_unsub := m.marketing_unsubscribed_at is not null and not m.marketing_consent;
  if v_m_unsub then
    v_consent := jsonb_build_object('action', 'unsubscribe_wins', 'result_consent', false,
      'result_unsubscribed_at', greatest(k.marketing_unsubscribed_at, m.marketing_unsubscribed_at));
    if k.marketing_consent then v_warn := v_warn || '["consent_removed_unsubscribed"]'::jsonb; end if;
  elsif not k.marketing_consent and m.marketing_consent and v_same_email and k.marketing_unsubscribed_at is null then
    v_consent := jsonb_build_object('action', 'inherit_consent', 'result_consent', true, 'result_unsubscribed_at', null);
  else
    v_consent := jsonb_build_object('action', 'unchanged', 'result_consent', k.marketing_consent, 'result_unsubscribed_at', k.marketing_unsubscribed_at);
    if m.marketing_consent and not k.marketing_consent and not v_same_email then v_warn := v_warn || '["consent_not_inherited_other_email"]'::jsonb; end if;
  end if;

  -- Johku-tunnisteet
  if m.external_source is not null then
    if k.external_source is null then v_johku := 'move_to_keep';
    else v_johku := 'both_keep_alias_on_merged'; v_warn := v_warn || '["johku_ids_both"]'::jsonb; end if;
  end if;
  if m.auth_user_id is not null and k.auth_user_id is null then v_warn := v_warn || '["login_moves_to_keep"]'::jsonb; end if;
  if nullif(btrim(coalesce(k.email, '')), '') is not null and nullif(btrim(coalesce(m.email, '')), '') is not null and not v_same_email then
    v_warn := v_warn || '["different_email"]'::jsonb;
  end if;

  -- tyhjät kentät täytetään yhdistetyltä (ei ylikirjoiteta)
  if nullif(btrim(coalesce(k.email, '')), '') is null and nullif(btrim(coalesce(m.email, '')), '') is not null then v_fill := array_append(v_fill, 'email'::text); end if;
  foreach f in array array['phone', 'address', 'zip', 'city', 'company', 'business_id', 'einvoice_address', 'einvoice_operator', 'invoice_reference'] loop
    if nullif(btrim(coalesce(to_jsonb(k) ->> f, '')), '') is null and nullif(btrim(coalesce(to_jsonb(m) ->> f, '')), '') is not null then v_fill := array_append(v_fill, f); end if;
  end loop;
  if nullif(btrim(coalesce(m.notes, '')), '') is not null then v_fill := array_append(v_fill, 'notes_append'::text); end if;

  -- tuntemattomat asiakastaulun triggerit (esim. PRODin booking_259/262 capture-hook) → varoitus, jotta ne tarkistetaan ennen käyttöönottoa
  select string_agg(tgname, ',' order by tgname) into v_trg from pg_trigger
   where tgrelid = 'booking.customers'::regclass and not tgisinternal
     and tgname not in ('audit_trg', 'customers_consent', 'customers_drop_event_notes', 'customers_updated', 'training_details_anonymize');
  if v_trg is not null then v_warn := v_warn || jsonb_build_array('unknown_customer_triggers:' || v_trg); end if;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_block) = 0, 'already_merged', v_already, 'blockers', v_block, 'warnings', v_warn,
    'keep', jsonb_build_object('id', k.id, 'name', k.name, 'email', k.email, 'phone', k.phone, 'kind', k.customer_kind, 'company', k.company,
      'created_at', k.created_at, 'consent', k.marketing_consent, 'external_source', k.external_source, 'external_id', k.external_id,
      'orders', (select count(*) from booking.orders o where o.customer_id = k.id)),
    'merge', jsonb_build_object('id', m.id, 'name', m.name, 'email', m.email, 'phone', m.phone, 'kind', m.customer_kind, 'company', m.company,
      'created_at', m.created_at, 'consent', m.marketing_consent, 'unsubscribed_at', m.marketing_unsubscribed_at,
      'external_source', m.external_source, 'external_id', m.external_id,
      'orders', (select count(*) from booking.orders o where o.customer_id = m.id)),
    'counts', v_counts, 'consent', v_consent, 'johku', v_johku, 'fill', to_jsonb(v_fill));
end $$;
revoke all on function booking._customer_merge_plan(bigint, bigint) from public, anon, authenticated;

create or replace function booking.admin_customer_admin_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return jsonb_build_object('can_admin', booking.has_permission('customers.admin'),
    'merge_enabled', booking._customer_flag('customer_merge_enabled'),
    'anonymize_enabled', booking._customer_flag('customer_anonymize_enabled'));
end $$;
revoke all on function booking.admin_customer_admin_status() from public, anon;
grant execute on function booking.admin_customer_admin_status() to authenticated, service_role;

create or replace function booking.admin_merge_customers_preview(p_keep bigint, p_merge bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('customers.admin');
  if not booking._customer_flag('customer_merge_enabled') then perform booking._err('merge_disabled', 'Asiakkaiden yhdistäminen ei ole käytössä'); end if;
  return booking._customer_merge_plan(p_keep, p_merge) || jsonb_build_object('applied', false);
end $$;
revoke all on function booking.admin_merge_customers_preview(bigint, bigint) from public, anon;
grant execute on function booking.admin_merge_customers_preview(bigint, bigint) to authenticated, service_role;

-- ---------- 7) yhdistäminen ----------
-- p_confirm = false → vain esikatselu (ei muutoksia). p_confirm = true → toteutus yhdessä transaktiossa.
-- Idempotentti: jo yhdistetty pari palauttaa already_merged ja siirtää korkeintaan välissä syntyneet jäännösviittaukset.
create or replace function booking.admin_merge_customers(p_keep bigint, p_merge bigint, p_confirm boolean default false, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  k booking.customers; m booking.customers; v_plan jsonb; v_block text; v_moved jsonb; v_log bigint; v_cons text; v_johku text;
  v_ext_src text; v_ext_id text; v_auth uuid; v_swept jsonb; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_same_email boolean; v_m_unsub boolean; v_keep_email text;
begin
  perform booking._require_permission('customers.admin');
  if not booking._customer_flag('customer_merge_enabled') then perform booking._err('merge_disabled', 'Asiakkaiden yhdistäminen ei ole käytössä'); end if;
  if p_keep is null or p_merge is null then perform booking._err('invalid_argument', 'Asiakkaan tunniste puuttuu'); end if;
  if p_keep = p_merge then perform booking._err('same_customer', 'Asiakasta ei voi yhdistää itseensä'); end if;
  if not coalesce(p_confirm, false) then
    return booking._customer_merge_plan(p_keep, p_merge) || jsonb_build_object('applied', false);
  end if;

  -- lukitus aina id-järjestyksessä (ei lukkiutumaa kahden samanaikaisen yhdistämisen välillä). FOR UPDATE estää myös uusien
  -- tilausten liittämisen näihin asiakkaisiin (FK-tarkistus odottaa) kesken siirron.
  perform 1 from booking.customers where id in (p_keep, p_merge) order by id for update;
  v_plan := booking._customer_merge_plan(p_keep, p_merge);

  if (v_plan ->> 'already_merged')::boolean then
    v_swept := booking._customer_move_refs(p_merge, p_keep);
    return v_plan || jsonb_build_object('applied', false, 'already_merged', true, 'swept', v_swept);
  end if;
  if not (v_plan ->> 'ok')::boolean then
    v_block := v_plan -> 'blockers' ->> 0;
    perform booking._err('merge_blocked', 'Yhdistäminen estetty: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(v_plan -> 'blockers') x));
  end if;

  select * into k from booking.customers where id = p_keep;
  select * into m from booking.customers where id = p_merge;
  v_cons := v_plan -> 'consent' ->> 'action';
  v_johku := v_plan ->> 'johku';
  v_same_email := nullif(btrim(coalesce(k.email, '')), '') is not null and lower(btrim(k.email)) = lower(btrim(coalesce(m.email, '')));
  v_m_unsub := m.marketing_unsubscribed_at is not null and not m.marketing_consent;
  v_keep_email := coalesce(nullif(btrim(coalesce(k.email, '')), ''), m.email);
  v_ext_src := m.external_source; v_ext_id := m.external_id; v_auth := m.auth_user_id;

  -- 1) suppression ensin: yhdistetyn osoite, jolta markkinointi on peruttu, ei saa palata listalle, vaikka osoite poistuu riviltä
  if v_m_unsub and nullif(btrim(coalesce(m.email, '')), '') is not null and lower(btrim(m.email)) is distinct from lower(btrim(coalesce(v_keep_email, ''))) then
    insert into booking.marketing_suppressions(email_hash, reason, source, customer_id, created_by)
    values (booking._email_hash(m.email), 'merged_unsubscribed', 'booking_285_merge', m.id, auth.uid()) on conflict (email_hash) do nothing;
  end if;

  -- 2) viittaukset (tilaukset, lahjakortit, vuosikortit, suostumushistoria, segmentit, kampanjat, laskuasiakkaat ...)
  --    Tunnisteet, joilla on uniikkirajoite, vapautetaan ennen siirtoa.
  if v_johku = 'move_to_keep' then update booking.customers set external_source = null, external_id = null where id = m.id; end if;
  if v_auth is not null and k.auth_user_id is null then update booking.customers set auth_user_id = null where id = m.id; end if;
  v_moved := booking._customer_move_refs(m.id, k.id);

  -- 3) säilytettävä asiakas: täydennetään tyhjät kentät, suostumus, Johku-tunniste, kirjautuminen
  update booking.customers c set
    email = case when nullif(btrim(coalesce(c.email, '')), '') is null then m.email else c.email end,
    phone = case when nullif(btrim(coalesce(c.phone, '')), '') is null then m.phone else c.phone end,
    address = case when nullif(btrim(coalesce(c.address, '')), '') is null then m.address else c.address end,
    zip = case when nullif(btrim(coalesce(c.zip, '')), '') is null then m.zip else c.zip end,
    city = case when nullif(btrim(coalesce(c.city, '')), '') is null then m.city else c.city end,
    company = case when nullif(btrim(coalesce(c.company, '')), '') is null then m.company else c.company end,
    business_id = case when nullif(btrim(coalesce(c.business_id, '')), '') is null then m.business_id else c.business_id end,
    einvoice_address = case when nullif(btrim(coalesce(c.einvoice_address, '')), '') is null then m.einvoice_address else c.einvoice_address end,
    einvoice_operator = case when nullif(btrim(coalesce(c.einvoice_operator, '')), '') is null then m.einvoice_operator else c.einvoice_operator end,
    invoice_reference = case when nullif(btrim(coalesce(c.invoice_reference, '')), '') is null then m.invoice_reference else c.invoice_reference end,
    notes = case when nullif(btrim(coalesce(m.notes, '')), '') is null then c.notes
                 else coalesce(nullif(btrim(c.notes), '') || E'\n\n', '') || '[Yhdistetty asiakas #' || m.id || '] ' || m.notes end,
    external_source = case when v_johku = 'move_to_keep' then v_ext_src else c.external_source end,
    external_id = case when v_johku = 'move_to_keep' then v_ext_id else c.external_id end,
    auth_user_id = case when c.auth_user_id is null then v_auth else c.auth_user_id end,
    marketing_consent = case v_cons when 'unsubscribe_wins' then false when 'inherit_consent' then true else c.marketing_consent end,
    marketing_consent_at = case when v_cons = 'inherit_consent' then m.marketing_consent_at else c.marketing_consent_at end,
    marketing_consent_source = case when v_cons = 'inherit_consent' then m.marketing_consent_source else c.marketing_consent_source end,
    marketing_consent_text_version = case when v_cons = 'inherit_consent' then m.marketing_consent_text_version else c.marketing_consent_text_version end,
    marketing_unsubscribed_at = case v_cons when 'unsubscribe_wins' then greatest(c.marketing_unsubscribed_at, m.marketing_unsubscribed_at)
                                            when 'inherit_consent' then null else c.marketing_unsubscribed_at end
   where c.id = k.id;

  -- 4) yhdistetty rivi hautakiveksi. Ensin vain osoite pois (consent-/capture-triggerit eivät näe osoitetta, kun suostumus perutaan),
  --    sitten loput. anonymized_at → rivi pois kaikista sähköpostihauista (ne suodattavat anonymized_at is null).
  update booking.customers set email = null, phone = null where id = m.id;
  update booking.customers set
    name = 'Yhdistetty asiakas #' || m.id, company = null, address = null, zip = null, city = null, notes = null,
    customer_kind = 'private', business_id = null, einvoice_address = null, einvoice_operator = null, invoice_reference = null,
    auth_user_id = null, customer_type = 'customer', marketing_consent = false, unsubscribe_token = gen_random_uuid(),
    merged_into = k.id, merged_at = now(), anonymized_at = now()
   where id = m.id;

  insert into booking.customer_merge_log(keep_id, merge_id, actor, actor_role, reason, merge_snapshot, moved, counts, warnings)
  values (k.id, m.id, auth.uid(), booking._jwt_role(), v_reason, to_jsonb(m) - 'unsubscribe_token', v_moved, v_plan -> 'counts', v_plan -> 'warnings')
  returning id into v_log;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data) values
    (auth.uid(), booking._jwt_role(), 'customers', k.id::text, 'MERGE', null,
       jsonb_build_object('merged_customer_id', m.id, 'merge_log_id', v_log, 'consent', v_cons, 'johku', v_johku, 'counts', v_plan -> 'counts', 'reason', v_reason)),
    (auth.uid(), booking._jwt_role(), 'customers', m.id::text, 'MERGED_INTO', null,
       jsonb_build_object('kept_customer_id', k.id, 'merge_log_id', v_log, 'reason', v_reason));

  return v_plan || jsonb_build_object('applied', true, 'already_merged', false, 'merge_log_id', v_log,
    'moved', (select coalesce(jsonb_object_agg(key, jsonb_build_object('moved', value -> 'moved', 'left', value -> 'left')), '{}'::jsonb) from jsonb_each(v_moved)));
end $$;
revoke all on function booking.admin_merge_customers(bigint, bigint, boolean, text) from public, anon;
grant execute on function booking.admin_merge_customers(bigint, bigint, boolean, text) to authenticated, service_role;

-- ---------- 8) anonymisointi (kytkin customer_anonymize_enabled, oletus POIS) ----------
-- Säilyy: tilaukset, varaukset, maksut, hyvitykset, kuitit, laskut, lahjakortit ja niiden kirjanpito, suostumushistoria (ilman henkilötietoja).
-- Poistuu/peittyy: asiakkaan nimi ja yhteystiedot, muistiinpanot, tilausten/varausten vapaat tekstit, lahjakortin ostajan tiedot,
-- kumppanikoodin asiakastiedot, jonotuslistan ja kampanjalähetysten osoitteet, audit_login henkilökentät, kirjautumistili (jonoon).
-- Uutiskirjeen suppression säilyy: osoitteen tiiviste kirjataan booking.marketing_suppressions-tauluun; email-avaimisia tauluja ei kosketa.
create or replace function booking._customer_anonymize_plan(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c booking.customers; v_block jsonb := '[]'::jsonb; v_warn jsonb := '[]'::jsonb; v_unpaid int; v_prot text;
begin
  if p_id is null then perform booking._err('invalid_argument', 'Asiakkaan tunniste puuttuu'); end if;
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  if c.anonymized_at is not null then
    return jsonb_build_object('ok', true, 'already_anonymized', true, 'blockers', '[]'::jsonb, 'warnings', '[]'::jsonb, 'counts', '{}'::jsonb,
      'customer', jsonb_build_object('id', c.id, 'merged_into', c.merged_into));
  end if;
  if exists (select 1 from booking.reservations r join booking.orders o on o.id = r.order_id
              where o.customer_id = c.id and r.status in ('pending', 'confirmed') and r.ends_at > now()) then
    v_block := v_block || '["future_reservations"]'::jsonb;
  end if;
  select count(*) into v_unpaid from booking.orders o
   where o.customer_id = c.id and o.status not in ('cancelled', 'expired', 'draft')
     and coalesce((booking._order_balance(o.id) ->> 'unpaid')::numeric, 0) > 0.004;
  if v_unpaid > 0 then v_block := v_block || '["unpaid_orders"]'::jsonb; end if;
  if exists (select 1 from booking.annual_cards a where a.customer_id = c.id and a.active and a.revoked_at is null and a.valid_to >= (now() at time zone 'Europe/Helsinki')::date) then
    v_block := v_block || '["active_annual_card"]'::jsonb;
  end if;
  if exists (select 1 from booking.email_outbox e join booking.orders o on o.id = e.order_id
              where o.customer_id = c.id and e.status in ('pending', 'sending', 'failed')) then
    v_block := v_block || '["pending_emails"]'::jsonb;
  end if;
  if exists (select 1 from booking.voucher_claims v join booking.orders o on o.id = v.order_id
              where o.customer_id = c.id and v.status in ('open', 'processing')) then
    v_block := v_block || '["open_voucher_claims"]'::jsonb;
  end if;
  if c.email is not null and exists (select 1 from booking.waitlist_entries w where lower(w.customer_email) = lower(c.email) and w.status in ('waiting', 'notified')) then
    v_block := v_block || '["active_waitlist"]'::jsonb;
  end if;
  if c.auth_user_id is not null then
    v_prot := booking._privacy_auth_protected(c.auth_user_id);
    if v_prot is not null then v_warn := v_warn || jsonb_build_array('login_account_kept:' || v_prot); end if;
  end if;
  if exists (select 1 from booking.gift_cards g where g.buyer_customer_id = c.id and g.status = 'active' and g.balance > 0) then
    v_warn := v_warn || '["active_gift_cards_remain_valid"]'::jsonb;
  end if;
  if c.external_source is not null then v_warn := v_warn || '["johku_customer_sync_skips_anonymized"]'::jsonb; end if;
  return jsonb_build_object('ok', jsonb_array_length(v_block) = 0, 'already_anonymized', false, 'blockers', v_block, 'warnings', v_warn,
    'customer', jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone, 'kind', c.customer_kind, 'company', c.company,
      'consent', c.marketing_consent, 'unsubscribed_at', c.marketing_unsubscribed_at, 'external_source', c.external_source),
    'counts', jsonb_build_object(
      'orders', (select count(*) from booking.orders o where o.customer_id = c.id),
      'reservations', (select count(*) from booking.reservations r join booking.orders o on o.id = r.order_id where o.customer_id = c.id),
      'payments', (select count(*) from booking.payments p join booking.orders o on o.id = p.order_id where o.customer_id = c.id),
      'receipts', (select count(*) from booking.receipts rc join booking.orders o on o.id = rc.order_id where o.customer_id = c.id),
      'gift_cards_bought', (select count(*) from booking.gift_cards g where g.buyer_customer_id = c.id),
      'voucher_claims', (select count(*) from booking.voucher_claims v join booking.orders o on o.id = v.order_id where o.customer_id = c.id),
      'campaign_sends', (select count(*) from booking.campaign_sends s where s.customer_id = c.id),
      'consent_events', (select count(*) from booking.marketing_consent_events e where e.customer_id = c.id)),
    'suppression', c.marketing_consent or c.marketing_unsubscribed_at is not null);
end $$;
revoke all on function booking._customer_anonymize_plan(bigint) from public, anon, authenticated;

create or replace function booking.admin_anonymize_customer_preview(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('customers.admin');
  if not booking._customer_flag('customer_anonymize_enabled') then perform booking._err('anonymize_disabled', 'Anonymisointi ei ole käytössä'); end if;
  return booking._customer_anonymize_plan(p_id) || jsonb_build_object('applied', false);
end $$;
revoke all on function booking.admin_anonymize_customer_preview(bigint) from public, anon;
grant execute on function booking.admin_anonymize_customer_preview(bigint) to authenticated, service_role;

create or replace function booking.admin_anonymize_customer(p_id bigint, p_reason text default null, p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c booking.customers; v_plan jsonb; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_old_email text; v_orders bigint[]; v_res bigint[]; v_gc bigint[]; v_vc bigint[]; v_cs bigint[]; v_wl bigint[]; v_n int; k record; v_ids bigint[]; v_counts jsonb := '{}'::jsonb;
begin
  perform booking._require_permission('customers.admin');
  -- kytkin ensin: pois päältä → virhe, eikä mitään muuteta eikä edes lueta asiakasta
  if not booking._customer_flag('customer_anonymize_enabled') then perform booking._err('anonymize_disabled', 'Anonymisointi ei ole käytössä'); end if;
  if p_id is null then perform booking._err('invalid_argument', 'Asiakkaan tunniste puuttuu'); end if;
  if not coalesce(p_confirm, false) then return booking._customer_anonymize_plan(p_id) || jsonb_build_object('applied', false); end if;
  if v_reason is null or char_length(v_reason) < 3 then perform booking._err('reason_required', 'Anonymisoinnin syy vaaditaan (vähintään 3 merkkiä)'); end if;

  select * into c from booking.customers where id = p_id for update;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  v_plan := booking._customer_anonymize_plan(p_id);
  if (v_plan ->> 'already_anonymized')::boolean then return v_plan || jsonb_build_object('applied', false); end if;
  if not (v_plan ->> 'ok')::boolean then
    perform booking._err('anonymize_blocked', 'Anonymisointi estetty: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(v_plan -> 'blockers') x));
  end if;

  v_old_email := c.email;
  select coalesce(array_agg(o.id), '{}') into v_orders from booking.orders o where o.customer_id = c.id;
  select coalesce(array_agg(r.id), '{}') into v_res from booking.reservations r where r.order_id = any (v_orders);
  select coalesce(array_agg(g.id), '{}') into v_gc from booking.gift_cards g where g.buyer_customer_id = c.id;
  select coalesce(array_agg(v.id), '{}') into v_vc from booking.voucher_claims v where v.order_id = any (v_orders) and v.status not in ('open', 'processing');
  select coalesce(array_agg(s.id), '{}') into v_cs from booking.campaign_sends s where s.customer_id = c.id;
  select coalesce(array_agg(w.id), '{}') into v_wl from booking.waitlist_entries w
   where v_old_email is not null and lower(w.customer_email) = lower(v_old_email) and w.status not in ('waiting', 'notified');

  -- suppression: osoite ei saa palata markkinointilistalle (vain tiiviste)
  if v_old_email is not null and (c.marketing_consent or c.marketing_unsubscribed_at is not null) then
    insert into booking.marketing_suppressions(email_hash, reason, source, customer_id, created_by)
    values (booking._email_hash(v_old_email), case when c.marketing_unsubscribed_at is not null and not c.marketing_consent then 'unsubscribed' else 'anonymized' end,
            'booking_285_anonymize', c.id, auth.uid())
    on conflict (email_hash) do nothing;
  end if;

  -- varausten ja tilausten vapaat tekstit (summat, maksut, kuitit, laskut ja lahjakorttikirjanpito säilyvät)
  update booking.orders o set customer_note = null, internal_note = null,
         billing = case when jsonb_typeof(o.billing) = 'object' then o.billing - array['email', 'phone', 'contact_name', 'contact_email', 'contact_phone'] else o.billing end
   where o.id = any (v_orders);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('orders', v_n);
  update booking.reservations r set notes = null, therapist_exception_note = null where r.id = any (v_res);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('reservations', v_n);
  update booking.voucher_claims v set customer_name = null, customer_email = null, customer_phone = null, notes = null where v.id = any (v_vc);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('voucher_claims', v_n);
  update booking.gift_cards g set buyer_name = null, buyer_email = null where g.id = any (v_gc);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('gift_cards', v_n);
  update booking.campaign_sends s set status = case when s.status = 'queued' then 'skipped_no_consent' else s.status end,
         email = 'poistettu@anonymisoitu.invalid', error = null where s.id = any (v_cs);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('campaign_sends', v_n);
  update booking.waitlist_entries w set customer_name = 'Anonymisoitu', customer_email = 'poistettu@anonymisoitu.invalid', customer_phone = null, whatsapp_opt_in = false
   where w.id = any (v_wl);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('waitlist_entries', v_n);

  -- kirjautumistili jonoon samalla tavalla kuin säilytysajon anonymisointi (henkilökunta ym. suojatut ohitetaan käsittelyssä)
  if c.auth_user_id is not null then
    insert into booking.privacy_auth_deletions(auth_user_id, customer_id) values (c.auth_user_id, c.id)
    on conflict (auth_user_id) do update set customer_id = excluded.customer_id, skipped_reason = null, queued_at = now()
     where booking.privacy_auth_deletions.deleted_at is null;
  end if;

  -- itse asiakasrivi: kuten säilytysajo (booking_160); yrityksen nimi ja Y-tunnus ovat yritystietoa ja säilyvät.
  -- marketing_unsubscribed_at säilyy (todiste peruutuksesta), suostumushistoria (marketing_consent_events) säilyy ilman henkilötietoja.
  update booking.customers x set name = 'Anonymisoitu asiakas', email = null, phone = null, address = null, zip = null, city = null, notes = null,
         company = case when x.customer_kind = 'company' then x.company end, business_id = case when x.customer_kind = 'company' then x.business_id end,
         einvoice_address = null, einvoice_operator = null, invoice_reference = null, auth_user_id = null,
         marketing_consent = false, unsubscribe_token = gen_random_uuid(), anonymized_at = now()
   where x.id = c.id;

  -- yhdistämislokin snapshotit, joissa tämä asiakas on säilytettävä
  update booking.customer_merge_log l set merge_snapshot = null where l.keep_id = c.id and l.merge_snapshot is not null;

  -- audit_log: henkilökentät pois tämän asiakkaan ja hänen rivien muutoshistoriasta (sama avainlista kuin säilytysajossa)
  for k in select * from booking._privacy_pii_keys() where tbl in ('customers', 'orders', 'reservations', 'voucher_claims', 'gift_cards', 'campaign_sends', 'waitlist_entries') loop
    v_ids := case k.tbl when 'customers' then array[c.id] when 'orders' then v_orders when 'reservations' then v_res when 'voucher_claims' then v_vc
                        when 'gift_cards' then v_gc when 'campaign_sends' then v_cs else v_wl end;
    update booking.audit_log a
       set old_data = case when a.old_data ?| k.keys then (a.old_data - k.keys) || '{"_pii_removed": true}'::jsonb else a.old_data end,
           new_data = case when a.new_data ?| k.keys then (a.new_data - k.keys) || '{"_pii_removed": true}'::jsonb else a.new_data end
     where a.table_name in (k.tbl, 'booking.' || k.tbl) and a.row_pk = any (select x::text from unnest(v_ids) x)
       and (coalesce(a.old_data ?| k.keys, false) or coalesce(a.new_data ?| k.keys, false));
  end loop;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'customers', c.id::text, 'ANONYMIZE', null, jsonb_build_object('reason', v_reason, 'counts', v_counts));

  return v_plan || jsonb_build_object('applied', true, 'already_anonymized', false, 'scrubbed', v_counts);
end $$;
revoke all on function booking.admin_anonymize_customer(bigint, text, boolean) from public, anon;
grant execute on function booking.admin_anonymize_customer(bigint, text, boolean) to authenticated, service_role;

comment on function booking.admin_merge_customers(bigint, bigint, boolean, text) is 'booking_285: yhdistää asiakkaan p_merge asiakkaaseen p_keep. p_confirm=false → esikatselu. Vaatii customers.admin + kytkimen customer_merge_enabled.';
comment on function booking.admin_anonymize_customer(bigint, text, boolean) is 'booking_285: anonymisoi asiakkaan (ei fyysistä poistoa; kirjanpitoaineisto säilyy). Kytkin customer_anonymize_enabled, oletus false → virhe anonymize_disabled, ei muutoksia.';
