-- ============================================================
-- booking_60_site_texts: asiakasnäkyvät tekstit tietokantaan (vaihe 1, vain tietokanta). Sopimus: KOODARI_talous_A_D_fi.md §18.
--  * booking.site_texts (nykyinen julkaistu teksti + sidonta lähdetaulun sarakkeeseen), booking.site_text_versions (historia, tilakone).
--  * Tilat: draft -> proposed -> approved -> published (+ superseded / rejected / stale). Luokat: normal | protected | locked.
--  * Rooli text_editor (vain texts.propose); manager: propose + approve; admin: kaikki (approve_protected, manage).
--  * Automaattinen eskalointi: numerot, €, %, kellonajat, puhelin, sähköposti, linkit -> vaatii texts.approve_protected.
--  * Seed: nykyiset tekstit lähdetauluista (kb.products, kb.faq, kb.policies, booking.addons/product_options/gift_card_packages/schedule_rules, kb.locations/opening_hours/event_dates/businesses).
--    Seed EI muuta mitään lähdedataa (sivut toimivat ennallaan). Julkaisu kirjoittaa hyväksytyn tekstin lähdesarakkeeseen; suora muokkaus lähdetaulussa synkataan versioksi triggerillä.
--  * Hintoja/ALV:tä/URL:eja ei muokata tämän kautta (locked-rivit näkyvät rekisterissä, ehdotus estetty). Artikkelit (booking.articles) pysyvät omassa luonnos->julkaisu-työnkulussaan.
-- Rollback: rollbacks/TEXTS_booking_60_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

-- ---------- rooli ja oikeudet ----------
insert into booking.roles (code, label, description, is_staff, sort_order)
values ('text_editor', 'Tekstieditori (botti)', 'Voi vain ehdottaa asiakasnäkyvien tekstien muutoksia (texts.propose). EI henkilöstörooli: ei pääsyä asiakas-, tilaus-, maksu- eikä hintatietoihin (booking.text_bots, ei booking.staff).', false, 40)
on conflict (code) do nothing;
insert into booking.role_permissions (role_code, permission) values
  ('text_editor', 'texts.propose'),
  ('manager', 'texts.propose'), ('manager', 'texts.approve'),
  ('admin', 'texts.propose'), ('admin', 'texts.approve'), ('admin', 'texts.approve_protected'), ('admin', 'texts.manage')
on conflict do nothing;
insert into booking.settings(key, value, description)
values ('texts_max_proposals_per_day', '200'::jsonb, 'Tekstiehdotusten enimmäismäärä / käyttäjä / 24 h (botit; hyväksyjät vapautettu)')
on conflict (key) do nothing;

-- ---------- taulut ----------
-- Botti-/tekstikäyttäjät: Supabase Auth -käyttäjä + rooli (text_editor). EI booking.staff-rivi, koska staff-rivi avaa RLS:n is_staff()-luvut (asiakkaat, tilaukset, maksut, asetukset).
create table booking.text_bots (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role_code text not null default 'text_editor' references booking.roles(code),
  label text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table booking.text_bots enable row level security;
revoke all on booking.text_bots from anon, authenticated;

create table booking.site_texts (
  id bigserial primary key,
  key text not null check (key ~ '^[a-z0-9_]+(\.[a-z0-9_-]+)+$' and char_length(key) <= 120),
  lang text not null check (lang in ('fi', 'en', 'all')),
  class text not null default 'normal' check (class in ('normal', 'protected', 'locked')),
  kind text not null default 'plain' check (kind in ('plain', 'lite')),
  max_len integer not null default 4000 check (max_len between 1 and 100000),
  placeholders text[] not null default '{}',
  source_table text check (source_table in ('kb.products', 'kb.faq', 'kb.policies', 'kb.locations', 'kb.opening_hours', 'kb.event_dates', 'kb.businesses',
                                            'booking.addons', 'booking.product_options', 'booking.gift_card_packages', 'booking.schedule_rules')),
  source_pk_col text check (source_pk_col in ('id', 'code')),
  source_pk text,
  source_column text check (source_column ~ '^[a-z_]+$'),
  published_text text not null default '',
  published_version integer not null default 0,
  latest_version integer not null default 0,
  status text not null default 'empty' check (status in ('empty', 'published', 'draft', 'proposed', 'approved')),
  needs_translation boolean not null default false,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (key, lang),
  check ((source_table is null) = (source_column is null) and (source_table is null) = (source_pk is null) and (source_table is null) = (source_pk_col is null)),
  check (lang <> 'all' or class = 'locked'),
  check (source_table is null or placeholders = '{}')      -- paikkamerkit vain irtotesteissä (build täyttää); lähdesarakkeeseen ei kirjoiteta raakoja {{...}}
);
create unique index site_texts_source_uq on booking.site_texts (source_table, source_pk, source_column, lang) where source_table is not null;
create index site_texts_key_idx on booking.site_texts (key text_pattern_ops);
create trigger site_texts_updated before update on booking.site_texts for each row execute function booking.set_updated_at();

create table booking.site_text_versions (
  id bigserial primary key,
  text_id bigint not null references booking.site_texts(id) on delete cascade,
  version integer not null,
  text text not null,
  status text not null check (status in ('draft', 'proposed', 'approved', 'published', 'superseded', 'rejected', 'stale')),
  base_version integer not null default 0,
  author uuid,
  author_kind text not null default 'human' check (author_kind in ('human', 'bot', 'system')),
  author_label text,
  reason text,
  escalation text[] not null default '{}',
  protected boolean not null default false,
  approved_by uuid,
  approved_at timestamptz,
  note text,
  published_by uuid,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  unique (text_id, version)
);
create index site_text_versions_status_idx on booking.site_text_versions (status) where status in ('draft', 'proposed', 'approved');

alter table booking.site_texts enable row level security;
alter table booking.site_text_versions enable row level security;
revoke all on booking.site_texts, booking.site_text_versions from anon, authenticated;
revoke all on sequence booking.site_texts_id_seq, booking.site_text_versions_id_seq from anon, authenticated;
grant select on booking.site_texts, booking.site_text_versions to authenticated;

-- ---------- apufunktiot ----------
create or replace function booking._text_tokens(p_text text, p_re text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(lower(m[1]) order by lower(m[1])), '{}'::text[]) from regexp_matches(coalesce(p_text, ''), p_re, 'g') m $$;

-- automaattinen eskalointi: mitkä "tosiasiat" muuttuvat vanhan ja uuden tekstin välillä
create or replace function booking._text_escalation(p_old text, p_new text) returns text[]
language plpgsql immutable set search_path = '' as $$
declare r text[] := '{}'; k text; re text;
begin
  for k, re in select * from (values
      ('numbers',  '(\d+(?:[.,]\d+)?)'),
      ('currency', '(€|\meur\M|\meuroa\M)'),
      ('percent',  '(%)'),
      ('time',     '(\d{1,2}[:.]\d{2})'),
      ('phone',    '(\+?\d[\d ]{6,}\d)'),
      ('email',    '([^\s@]+@[^\s@]+\.[^\s@]+)'),
      ('link',     '(https?://\S+|www\.\S+|\]\([^)]*\))')) v(k, re) loop
    if booking._text_tokens(p_old, re) is distinct from booking._text_tokens(p_new, re) then r := r || k; end if;
  end loop;
  return r;
end $$;

create or replace function booking._text_validate(p_class text, p_kind text, p_max integer, p_placeholders text[], p_text text) returns void
language plpgsql immutable set search_path = '' as $$
declare m text[]; v_clean text; v_set text[];
begin
  if p_text is null or btrim(p_text) = '' then perform booking._err('text_empty', 'Teksti ei voi olla tyhjä'); end if;
  if char_length(p_text) > p_max then perform booking._err('too_long', format('Teksti on liian pitkä (%s > %s merkkiä)', char_length(p_text), p_max)); end if;
  if p_text ~ '[\x01-\x08\x0B\x0C\x0E-\x1F]' then perform booking._err('invalid_text', 'Tekstissä on kiellettyjä ohjausmerkkejä'); end if;
  if p_text ~ '<\s*/?\s*[A-Za-z!?]' or p_text ~* 'javascript:' or p_text ~* '\mon[a-z]+\s*=\s*["'']' then perform booking._err('html_not_allowed', 'Raaka HTML tai skripti ei ole sallittu (vain tekstiä)'); end if;
  if p_kind = 'plain' and p_text ~ '\]\(' then perform booking._err('markup_not_allowed', 'Linkkimerkintä ei ole sallittu tässä tekstikentässä'); end if;
  select coalesce(array_agg(distinct x[1] order by x[1]), '{}') into v_set from regexp_matches(p_text, '(\{\{[^{}]*\}\})', 'g') x;
  if exists (select 1 from unnest(v_set) s where s !~ '^\{\{[a-z_]+(:[A-Za-z0-9_]+)?\}\}$') then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  v_clean := regexp_replace(p_text, '\{\{[^{}]*\}\}', '', 'g');
  if v_clean ~ '\{\{|\}\}' then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  if v_set is distinct from (select coalesce(array_agg(distinct s order by s), '{}') from unnest(p_placeholders) s) then
    perform booking._err('placeholder_mismatch', 'Paikkamerkkien pitää vastata tämän tekstin sallittuja paikkamerkkejä');
  end if;
end $$;


-- palvelutaso (service_role / suora tietokantayhteys) ohittaa oikeudet, kuten _article_auth; henkilöstö: role_permissions; botit: booking.text_bots -> text_editor-roolin oikeudet
create or replace function booking._text_is_service() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(booking._jwt_role(), '') = 'service_role' or (booking._jwt_role() is null and session_user in ('postgres', 'supabase_admin', 'service_role')) $$;
create or replace function booking._text_bot_role() returns text language sql stable security definer set search_path = '' as $$
  select tb.role_code from booking.text_bots tb join booking.roles r on r.code = tb.role_code and r.active where tb.user_id = auth.uid() and tb.active $$;
create or replace function booking._text_has(p_perm text) returns boolean language sql stable security definer set search_path = '' as $$
  select booking._text_is_service() or booking.has_permission(p_perm)
      or exists (select 1 from booking.role_permissions rp where rp.role_code = booking._text_bot_role() and rp.permission = p_perm) $$;
create or replace function booking._text_perm(p_perm text) returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not booking._text_has(p_perm) then perform booking._err('forbidden', 'Ei oikeutta tähän toimintoon (' || p_perm || ')'); end if;
end $$;
create or replace function booking._text_perm_any(p_perms text[]) returns void language plpgsql stable security definer set search_path = '' as $$
declare x text;
begin
  foreach x in array p_perms loop if booking._text_has(x) then return; end if; end loop;
  perform booking._err('forbidden', 'Ei oikeutta tähän toimintoon (' || p_perms[1] || ')');
end $$;

create or replace function booking._text_actor_kind() returns text language sql stable security definer set search_path = '' as $$
  select case when booking._text_bot_role() is not null then 'bot' when auth.uid() is null then 'system' else 'human' end $$;

create policy site_texts_staff_read on booking.site_texts for select to authenticated
  using ((select booking._text_has('texts.propose') or booking._text_has('texts.approve') or booking._text_has('texts.manage')));
create policy site_text_versions_staff_read on booking.site_text_versions for select to authenticated
  using ((select booking._text_has('texts.propose') or booking._text_has('texts.approve') or booking._text_has('texts.manage')));

create or replace function booking._text_audit(p_action text, p_text_id bigint, p_version integer, p_data jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.site_texts', p_text_id::text || ':' || p_version::text, p_action, null, p_data) $$;

create or replace function booking._text_refresh(p_text_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_st text; v_latest int;
begin
  select max(version) into v_latest from booking.site_text_versions where text_id = p_text_id;
  select case when exists (select 1 from booking.site_text_versions where text_id = p_text_id and status = 'approved') then 'approved'
              when exists (select 1 from booking.site_text_versions where text_id = p_text_id and status = 'proposed') then 'proposed'
              when exists (select 1 from booking.site_text_versions where text_id = p_text_id and status = 'draft') then 'draft'
              when (select published_version from booking.site_texts where id = p_text_id) > 0 then 'published' else 'empty' end into v_st;
  update booking.site_texts set status = v_st, latest_version = coalesce(v_latest, 0) where id = p_text_id;
end $$;

-- julkaisu: kirjoittaa lähdesarakkeeseen (jos sidottu), vanha julkaistu -> superseded, avoimet vanhentuneet -> stale
create or replace function booking._text_publish(p_version_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v booking.site_text_versions; t booking.site_texts; n int;
begin
  select * into v from booking.site_text_versions where id = p_version_id for update;
  select * into t from booking.site_texts where id = v.text_id for update;
  if t.source_table is not null then
    perform set_config('booking.text_apply', 'on', true);
    execute format('update %s set %I = $1 where %I::text = $2', t.source_table, t.source_column, t.source_pk_col) using v.text, t.source_pk;
    get diagnostics n = row_count;
    perform set_config('booking.text_apply', '', true);
    if n <> 1 then perform booking._err('source_missing', 'Lähderiviä ei löydy tekstille ' || t.key); end if;
  end if;
  update booking.site_text_versions set status = 'superseded' where text_id = t.id and status = 'published' and id <> v.id;
  update booking.site_text_versions set status = 'stale', note = coalesce(note || ' | ', '') || 'vanhentunut: toinen versio julkaistiin'
   where text_id = t.id and id <> v.id and status in ('draft', 'proposed', 'approved') and version < v.version;
  update booking.site_text_versions set status = 'published', published_by = auth.uid(), published_at = now() where id = v.id;
  update booking.site_texts set published_text = v.text, published_version = v.version, published_at = now(), needs_translation = false where id = t.id;
  if t.lang in ('fi', 'en') then
    update booking.site_texts set needs_translation = true where key = t.key and lang in ('fi', 'en') and lang <> t.lang and published_version > 0;
  end if;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_PUBLISH', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'protected', v.protected, 'escalation', v.escalation));
end $$;

create or replace function booking._text_row(p_key text, p_lang text, p_lock boolean default false) returns booking.site_texts
language plpgsql security definer set search_path = '' as $$
declare t booking.site_texts;
begin
  if p_lock then select * into t from booking.site_texts where key = lower(btrim(p_key)) and lang = lower(btrim(p_lang)) for update;
  else select * into t from booking.site_texts where key = lower(btrim(p_key)) and lang = lower(btrim(p_lang)); end if;
  if not found then perform booking._err('not_found', 'Tekstiä ei löydy'); end if;
  return t;
end $$;

create or replace function booking._text_need_approve(p_protected boolean) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_protected then perform booking._text_perm('texts.approve_protected');
  else perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']); end if;
end $$;

create or replace function booking._text_json(t booking.site_texts) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'key', t.key, 'lang', t.lang, 'class', t.class, 'kind', t.kind, 'max_len', t.max_len, 'placeholders', to_jsonb(t.placeholders),
    'text', t.published_text, 'version', t.published_version, 'status', t.status, 'needs_translation', t.needs_translation, 'published_at', t.published_at,
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'version', v.version, 'status', v.status, 'text', v.text, 'protected', v.protected, 'escalation', to_jsonb(v.escalation),
                  'author_kind', v.author_kind, 'author_label', v.author_label, 'reason', v.reason, 'created_at', v.created_at) order by v.version), '[]'::jsonb)
                  from booking.site_text_versions v where v.text_id = t.id and v.status in ('draft', 'proposed', 'approved'))) $$;

-- ---------- ehdotus (texts.propose) ----------
create or replace function booking.texts_propose(p_key text, p_lang text, p_text text, p_reason text default null, p_draft boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare t booking.site_texts; v_esc text[]; v_prot boolean; v_ver int; v_id bigint; v_max int; v_n int;
begin
  perform booking._text_perm('texts.propose');
  t := booking._text_row(p_key, p_lang, true);
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu (hinnat, ALV, URL:t ja vastaavat); sitä ei voi ehdottaa'); end if;
  perform booking._text_validate(t.class, t.kind, t.max_len, t.placeholders, p_text);
  if p_text = t.published_text then perform booking._err('no_change', 'Teksti ei eroa julkaistusta'); end if;
  if not (booking._text_has('texts.approve') or booking._text_has('texts.approve_protected')) then
    v_max := coalesce((select (value #>> '{}')::int from booking.settings where key = 'texts_max_proposals_per_day'), 200);
    select count(*) into v_n from booking.site_text_versions where author = auth.uid() and created_at > now() - interval '24 hours';
    if v_n >= v_max then perform booking._err('rate_limited', 'Päivittäinen ehdotusraja täynnä'); end if;
  end if;
  v_esc := booking._text_escalation(t.published_text, p_text);
  v_prot := t.class = 'protected' or cardinality(v_esc) > 0;
  update booking.site_text_versions set status = 'superseded', note = 'korvattu uudella ehdotuksella'
   where text_id = t.id and status in ('draft', 'proposed') and author is not distinct from auth.uid();
  select coalesce(max(version), 0) + 1 into v_ver from booking.site_text_versions where text_id = t.id;
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author, author_kind, author_label, reason, escalation, protected)
  values (t.id, v_ver, p_text, case when p_draft then 'draft' else 'proposed' end, t.published_version, auth.uid(), booking._text_actor_kind(),
          coalesce(auth.uid()::text, 'sql'), nullif(btrim(coalesce(p_reason, '')), ''), v_esc, v_prot) returning id into v_id;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_PROPOSE', t.id, v_ver, jsonb_build_object('key', t.key, 'lang', t.lang, 'protected', v_prot, 'escalation', v_esc, 'draft', p_draft));
  return jsonb_build_object('ok', true, 'version_id', v_id, 'version', v_ver, 'status', case when p_draft then 'draft' else 'proposed' end,
                            'protected', v_prot, 'escalation', to_jsonb(v_esc), 'approver', case when v_prot then 'texts.approve_protected' else 'texts.approve' end);
end $$;

create or replace function booking.texts_submit(p_version_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v booking.site_text_versions; t booking.site_texts; v_esc text[]; v_prot boolean;
begin
  perform booking._text_perm('texts.propose');
  select * into v from booking.site_text_versions where id = p_version_id for update;
  if not found then perform booking._err('not_found', 'Versiota ei löydy'); end if;
  if v.author is distinct from auth.uid() and not booking._text_has('texts.approve_protected') then perform booking._err('forbidden', 'Vain oman luonnoksen voi lähettää'); end if;
  if v.status <> 'draft' then perform booking._err('bad_state', 'Vain luonnoksen voi lähettää'); end if;
  select * into t from booking.site_texts where id = v.text_id for update;
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu'); end if;
  if v.base_version <> t.published_version then
    update booking.site_text_versions set status = 'stale' where id = v.id; perform booking._text_refresh(t.id);
    perform booking._err('stale_base', 'Julkaistu teksti on muuttunut; tee uusi ehdotus');
  end if;
  perform booking._text_validate(t.class, t.kind, t.max_len, t.placeholders, v.text);
  v_esc := booking._text_escalation(t.published_text, v.text); v_prot := t.class = 'protected' or cardinality(v_esc) > 0;
  update booking.site_text_versions set status = 'proposed', escalation = v_esc, protected = v_prot where id = v.id;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_SUBMIT', t.id, v.version, jsonb_build_object('key', t.key, 'protected', v_prot));
  return jsonb_build_object('ok', true, 'version_id', v.id, 'status', 'proposed', 'protected', v_prot, 'escalation', to_jsonb(v_esc));
end $$;

create or replace function booking.texts_withdraw(p_version_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v booking.site_text_versions;
begin
  perform booking._text_perm('texts.propose');
  select * into v from booking.site_text_versions where id = p_version_id for update;
  if not found then perform booking._err('not_found', 'Versiota ei löydy'); end if;
  if v.author is distinct from auth.uid() then perform booking._err('forbidden', 'Vain oman ehdotuksen voi vetää pois'); end if;
  if v.status not in ('draft', 'proposed') then perform booking._err('bad_state', 'Ehdotusta ei voi vetää pois tässä tilassa'); end if;
  update booking.site_text_versions set status = 'rejected', note = 'vedetty pois' where id = v.id;
  perform booking._text_refresh(v.text_id);
  perform booking._text_audit('TEXT_WITHDRAW', v.text_id, v.version);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- luku (texts.propose / approve / manage) ----------
create or replace function booking.texts_list(p_prefix text default null, p_lang text default null, p_status text default null, p_missing boolean default false,
                                              p_limit integer default 200, p_offset integer default 0) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lim int := least(greatest(coalesce(p_limit, 200), 1), 500); v_total int; v_items jsonb;
begin
  perform booking._text_perm_any(array['texts.propose', 'texts.approve', 'texts.manage']);
  select count(*) into v_total from booking.site_texts t
   where (p_prefix is null or t.key like lower(btrim(p_prefix)) || '%') and (p_lang is null or t.lang = p_lang) and (p_status is null or t.status = p_status)
     and (not coalesce(p_missing, false) or (t.published_text = '' and t.class <> 'locked'));
  select coalesce(jsonb_agg(booking._text_json(x) order by x.key, x.lang), '[]'::jsonb) into v_items from (
    select * from booking.site_texts t
     where (p_prefix is null or t.key like lower(btrim(p_prefix)) || '%') and (p_lang is null or t.lang = p_lang) and (p_status is null or t.status = p_status)
       and (not coalesce(p_missing, false) or (t.published_text = '' and t.class <> 'locked'))
     order by t.key, t.lang limit v_lim offset greatest(coalesce(p_offset, 0), 0)) x;
  return jsonb_build_object('ok', true, 'total', v_total, 'items', v_items);
end $$;

create or replace function booking.texts_get(p_key text, p_lang text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare t booking.site_texts;
begin
  perform booking._text_perm_any(array['texts.propose', 'texts.approve', 'texts.manage']);
  t := booking._text_row(p_key, p_lang);
  return jsonb_build_object('ok', true, 'text', booking._text_json(t),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'version', v.version, 'status', v.status, 'text', v.text, 'base_version', v.base_version, 'protected', v.protected,
                  'escalation', to_jsonb(v.escalation), 'author_kind', v.author_kind, 'author_label', v.author_label, 'reason', v.reason, 'approved_at', v.approved_at,
                  'published_at', v.published_at, 'note', v.note, 'created_at', v.created_at) order by v.version desc), '[]'::jsonb)
                 from booking.site_text_versions v where v.text_id = t.id));
end $$;

-- ---------- hyväksyntä (texts.approve: tavalliset; texts.approve_protected: suojatut) ----------
create or replace function booking.admin_texts_queue(p_protected boolean default null, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']);
  return jsonb_build_object('ok', true, 'items', (select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'version', v.version, 'key', t.key, 'lang', t.lang, 'class', t.class,
      'current_text', t.published_text, 'proposed_text', v.text, 'protected', v.protected, 'escalation', to_jsonb(v.escalation), 'author_kind', v.author_kind, 'author_label', v.author_label,
      'reason', v.reason, 'created_at', v.created_at, 'can_approve', (not v.protected) or booking._text_has('texts.approve_protected'), 'stale', v.base_version <> t.published_version)
      order by v.created_at), '[]'::jsonb)
    from (select * from booking.site_text_versions where status = 'proposed' order by created_at limit least(greatest(coalesce(p_limit, 100), 1), 500)) v
    join booking.site_texts t on t.id = v.text_id where p_protected is null or v.protected = p_protected));
end $$;

create or replace function booking.admin_texts_approve(p_version_id bigint, p_note text default null, p_publish boolean default true) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v booking.site_text_versions; t booking.site_texts; v_esc text[]; v_prot boolean;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']);
  select * into v from booking.site_text_versions where id = p_version_id for update;
  if not found then perform booking._err('not_found', 'Versiota ei löydy'); end if;
  select * into t from booking.site_texts where id = v.text_id for update;
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu'); end if;
  if v.status <> 'proposed' then perform booking._err('bad_state', 'Vain ehdotetun version voi hyväksyä (tila: ' || v.status || ')'); end if;
  if v.base_version <> t.published_version then
    update booking.site_text_versions set status = 'stale', note = 'vanhentunut' where id = v.id; perform booking._text_refresh(t.id);
    perform booking._err('stale_base', 'Julkaistu teksti on muuttunut ehdotuksen jälkeen; ehdota uudelleen');
  end if;
  v_esc := booking._text_escalation(t.published_text, v.text); v_prot := t.class = 'protected' or cardinality(v_esc) > 0;
  perform booking._text_need_approve(v_prot);
  if v.author is not null and v.author = auth.uid() and not booking._text_has('texts.approve_protected') then
    perform booking._err('self_approval', 'Omaa ehdotusta ei voi hyväksyä itse');
  end if;
  perform booking._text_validate(t.class, t.kind, t.max_len, t.placeholders, v.text);
  update booking.site_text_versions set status = 'approved', approved_by = auth.uid(), approved_at = now(), note = nullif(btrim(coalesce(p_note, '')), ''), escalation = v_esc, protected = v_prot where id = v.id;
  perform booking._text_audit('TEXT_APPROVE', t.id, v.version, jsonb_build_object('key', t.key, 'protected', v_prot));
  if coalesce(p_publish, true) then perform booking._text_publish(v.id); else perform booking._text_refresh(t.id); end if;
  return jsonb_build_object('ok', true, 'version_id', v.id, 'status', case when coalesce(p_publish, true) then 'published' else 'approved' end, 'protected', v_prot);
end $$;

create or replace function booking.admin_texts_publish(p_version_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v booking.site_text_versions; t booking.site_texts;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']);
  select * into v from booking.site_text_versions where id = p_version_id for update;
  if not found then perform booking._err('not_found', 'Versiota ei löydy'); end if;
  select * into t from booking.site_texts where id = v.text_id for update;
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu'); end if;
  if v.status <> 'approved' then perform booking._err('bad_state', 'Vain hyväksytyn version voi julkaista'); end if;
  if v.base_version <> t.published_version then
    update booking.site_text_versions set status = 'stale' where id = v.id; perform booking._text_refresh(t.id);
    perform booking._err('stale_base', 'Julkaistu teksti on muuttunut; ehdota uudelleen');
  end if;
  perform booking._text_need_approve(v.protected or t.class = 'protected');
  perform booking._text_publish(v.id);
  return jsonb_build_object('ok', true, 'version_id', v.id, 'status', 'published');
end $$;

create or replace function booking.admin_texts_reject(p_version_id bigint, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v booking.site_text_versions; t booking.site_texts;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']);
  select * into v from booking.site_text_versions where id = p_version_id for update;
  if not found then perform booking._err('not_found', 'Versiota ei löydy'); end if;
  select * into t from booking.site_texts where id = v.text_id for update;
  perform booking._text_need_approve(v.protected or t.class = 'protected');
  if v.status not in ('proposed', 'approved', 'draft') then perform booking._err('bad_state', 'Tilaa ei voi hylätä (tila: ' || v.status || ')'); end if;
  update booking.site_text_versions set status = 'rejected', note = nullif(btrim(coalesce(p_note, '')), '') where id = v.id;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_REJECT', t.id, v.version, jsonb_build_object('key', t.key));
  return jsonb_build_object('ok', true, 'version_id', v.id, 'status', 'rejected');
end $$;

-- peruutus: julkaise aiempi versio uutena versiona (historia säilyy)
create or replace function booking.admin_texts_rollback(p_key text, p_lang text, p_to_version integer, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare t booking.site_texts; tv booking.site_text_versions; v_esc text[]; v_prot boolean; v_ver int; v_id bigint;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']);
  t := booking._text_row(p_key, p_lang, true);
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu'); end if;
  select * into tv from booking.site_text_versions where text_id = t.id and version = p_to_version and status in ('published', 'superseded');
  if not found then perform booking._err('not_found', 'Palautettavaa julkaistua versiota ei löydy'); end if;
  if tv.text = t.published_text then perform booking._err('no_change', 'Versio on jo julkaistu'); end if;
  v_esc := booking._text_escalation(t.published_text, tv.text); v_prot := t.class = 'protected' or cardinality(v_esc) > 0;
  perform booking._text_need_approve(v_prot);
  select max(version) + 1 into v_ver from booking.site_text_versions where text_id = t.id;
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author, author_kind, author_label, reason, escalation, protected, approved_by, approved_at, note)
  values (t.id, v_ver, tv.text, 'approved', t.published_version, auth.uid(), booking._text_actor_kind(), coalesce(auth.uid()::text, 'sql'),
          'Palautus versioon ' || p_to_version, v_esc, v_prot, auth.uid(), now(), nullif(btrim(coalesce(p_note, '')), '')) returning id into v_id;
  perform booking._text_audit('TEXT_ROLLBACK', t.id, v_ver, jsonb_build_object('key', t.key, 'to_version', p_to_version));
  perform booking._text_publish(v_id);
  return jsonb_build_object('ok', true, 'version_id', v_id, 'version', v_ver, 'status', 'published', 'protected', v_prot);
end $$;

-- ---------- ylläpito (texts.manage = admin) ----------
create or replace function booking.admin_texts_set_class(p_key text, p_lang text, p_class text, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare t booking.site_texts;
begin
  perform booking._text_perm('texts.manage');
  if p_class not in ('normal', 'protected', 'locked') then perform booking._err('invalid_class', 'Luokka: normal | protected | locked'); end if;
  t := booking._text_row(p_key, p_lang, true);
  if t.lang = 'all' and p_class <> 'locked' then perform booking._err('invalid_class', 'Kieliriippumaton teksti voi olla vain lukittu'); end if;
  update booking.site_texts set class = p_class where id = t.id;
  if p_class = 'locked' then update booking.site_text_versions set status = 'rejected', note = 'lukittu' where text_id = t.id and status in ('draft', 'proposed', 'approved'); end if;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_SET_CLASS', t.id, t.latest_version, jsonb_build_object('key', t.key, 'old', t.class, 'new', p_class, 'note', p_note));
  return jsonb_build_object('ok', true, 'key', t.key, 'class', p_class);
end $$;

-- lähdetaulujen rekisteröinti (idempotentti): lisää puuttuvat rivit, ei muuta olemassa olevia tekstejä
create or replace function booking._texts_reg(p_table text, p_pk_col text, p_prefix text, p_field text, p_column text, p_lang_sql text, p_class_sql text, p_where text, p_max integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  execute format($q$insert into booking.site_texts(key, lang, class, kind, max_len, source_table, source_pk_col, source_pk, source_column, published_text, published_version, latest_version, status)
    select %1$L || '.' || s.%2$I::text || '.' || %3$L, %4$s, %5$s, 'plain', %6$s, %7$L, %2$L, s.%2$I::text, %8$L, coalesce(s.%8$I, ''),
           case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end, case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end,
           case when btrim(coalesce(s.%8$I, '')) <> '' then 'published' else 'empty' end
      from %7$s s where %9$s on conflict do nothing$q$, p_prefix, p_pk_col, p_field, p_lang_sql, p_class_sql, p_max, p_table, p_column, p_where);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function booking._texts_register_sources() returns integer
language plpgsql security definer set search_path = '' as $fn$
declare n integer := 0; c text; pc text := $c$case when lower(coalesce(s.category, '')) in ('hinnat','varaaminen','booking','maksaminen','opening_hours','aukioloajat','käytännöt','practical','payment','cancellation','safety','accessibility','privacy','gift_card','season_card','training_terms','house_rules','dress_code') then 'protected' else 'normal' end$c$;
begin
  -- kb.products (aktiiviset): nimet/kuvaukset normal; kesto protected; hinta/slug/URL locked
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name', $$'fi'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name_en', $$'en'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description', $$'fi'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description_en', $$'en'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'duration_text', 'duration_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'price_text', 'price_text', $$'fi'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'slug', 'slug', $$'all'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'booking_url', 'booking_url', $$'all'$$, $$'locked'$$, 's.active', 500);
  -- UKK
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 6000);
  -- ehdot ja käytännöt (kaikki protected)
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 300);
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 20000);
  -- lisäpalvelut, tuotevalinnat, lahjakorttipaketit, vuorojen nimet
  foreach c in array array['name', 'description'] loop
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
  end loop;
  n := n + booking._texts_reg('booking.schedule_rules', 'id', 'schedule', 'label', 'label', $$'fi'$$, $$'normal'$$, 's.active', 200);
  -- sijainnit, aukioloajat, tapahtumat, yritys (kaikki protected: tosiasiat)
  foreach c in array array['name', 'description', 'directions', 'parking', 'public_transport', 'accessibility'] loop
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c, $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 3000);
  end loop;
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 500);
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 4000);
  -- seed-versiot (versio 1 = nykyinen lähdeteksti)
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
  select t.id, 1, t.published_text, 'published', 0, 'system', 'seed booking_60', 'Alkutila lähdetaulusta', now(), '{}', false
    from booking.site_texts t where t.published_version = 1 and not exists (select 1 from booking.site_text_versions v where v.text_id = t.id);
  return n;
end $fn$;

create or replace function booking.admin_texts_sync() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  perform booking._text_perm('texts.manage');
  n := booking._texts_register_sources();
  perform booking._text_audit('TEXT_SYNC', 0, 0, jsonb_build_object('added', n));
  return jsonb_build_object('ok', true, 'added', n);
end $$;

create or replace function booking.admin_texts_drift() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; v_cur text; out jsonb := '[]'::jsonb;
begin
  perform booking._text_perm_any(array['texts.manage', 'texts.approve']);
  for r in select * from booking.site_texts where source_table is not null loop
    execute format('select %I::text from %s where %I::text = $1', r.source_column, r.source_table, r.source_pk_col) into v_cur using r.source_pk;
    if coalesce(v_cur, '') is distinct from r.published_text then out := out || jsonb_build_array(jsonb_build_object('key', r.key, 'lang', r.lang, 'source_text', v_cur, 'published_text', r.published_text)); end if;
  end loop;
  return jsonb_build_object('ok', true, 'drift', out);
end $$;

-- suora muokkaus lähdetaulussa -> uusi julkaistu versio (ei silmukkaa: julkaisu asettaa booking.text_apply)
create or replace function booking._text_source_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r booking.site_texts; v_new text; v_ver int; v_pk text := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'code');
begin
  if coalesce(current_setting('booking.text_apply', true), '') = 'on' then return null; end if;
  for r in select * from booking.site_texts t where t.source_table = tg_table_schema || '.' || tg_table_name and t.source_pk = v_pk loop
    v_new := coalesce(to_jsonb(new) ->> r.source_column, '');
    continue when v_new = r.published_text;
    select coalesce(max(version), 0) + 1 into v_ver from booking.site_text_versions where text_id = r.id;
    update booking.site_text_versions set status = 'superseded' where text_id = r.id and status = 'published';
    update booking.site_text_versions set status = 'stale', note = 'vanhentunut: lähdetaulua muokattu suoraan' where text_id = r.id and status in ('draft', 'proposed', 'approved');
    insert into booking.site_text_versions(text_id, version, text, status, base_version, author, author_kind, author_label, reason, published_by, published_at, escalation, protected)
    values (r.id, v_ver, v_new, 'published', r.published_version, auth.uid(), case when auth.uid() is null then 'system' else 'human' end, coalesce(auth.uid()::text, 'sql'),
            'Muokattu suoraan lähdetaulussa (' || tg_table_schema || '.' || tg_table_name || ')', auth.uid(), now(), booking._text_escalation(r.published_text, v_new), false);
    update booking.site_texts set published_text = v_new, published_version = v_ver, published_at = now(),
           needs_translation = false where id = r.id;
    if r.lang in ('fi', 'en') then update booking.site_texts set needs_translation = true where key = r.key and lang in ('fi', 'en') and lang <> r.lang and published_version > 0; end if;
    perform booking._text_refresh(r.id);
    perform booking._text_audit('TEXT_DIRECT_EDIT', r.id, v_ver, jsonb_build_object('key', r.key, 'table', tg_table_schema || '.' || tg_table_name));
  end loop;
  return null;
end $$;

do $$
declare x text;
begin
  foreach x in array array['kb.products', 'kb.faq', 'kb.policies', 'kb.locations', 'kb.opening_hours', 'kb.event_dates', 'kb.businesses',
                           'booking.addons', 'booking.product_options', 'booking.gift_card_packages', 'booking.schedule_rules'] loop
    execute format('drop trigger if exists zz_site_text_sync on %s', x);
    execute format('create trigger zz_site_text_sync after update on %s for each row execute function booking._text_source_changed()', x);
  end loop;
end $$;

-- ---------- julkinen luku (vain julkaistut, ei lukitut, ei tyhjät) ----------
create or replace function booking.public_get_site_texts(p_lang text default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'generated_at', now(), 'texts', coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'lang', t.lang, 'text', t.published_text, 'version', t.published_version)
                                                                                           order by t.key, t.lang), '[]'::jsonb))
    from booking.site_texts t
   where t.published_version > 0 and t.published_text <> '' and t.class <> 'locked' and (p_lang is null or t.lang = lower(btrim(p_lang))) $$;

-- ---------- oikeudet ----------
do $$
declare f text;
begin
  foreach f in array array[
    'booking._text_is_service()', 'booking._text_bot_role()', 'booking._text_has(text)', 'booking._text_perm(text)', 'booking._text_perm_any(text[])', 'booking._text_tokens(text,text)', 'booking._text_escalation(text,text)', 'booking._text_validate(text,text,integer,text[],text)', 'booking._text_actor_kind()',
    'booking._text_audit(text,bigint,integer,jsonb)', 'booking._text_refresh(bigint)', 'booking._text_publish(bigint)', 'booking._text_row(text,text,boolean)',
    'booking._text_need_approve(boolean)', 'booking._text_json(booking.site_texts)', 'booking._texts_reg(text,text,text,text,text,text,text,text,integer)',
    'booking._texts_register_sources()', 'booking._text_source_changed()',
    'booking.texts_propose(text,text,text,text,boolean)', 'booking.texts_submit(bigint)', 'booking.texts_withdraw(bigint)', 'booking.texts_list(text,text,text,boolean,integer,integer)',
    'booking.texts_get(text,text)', 'booking.admin_texts_queue(boolean,integer)', 'booking.admin_texts_approve(bigint,text,boolean)', 'booking.admin_texts_publish(bigint)',
    'booking.admin_texts_reject(bigint,text)', 'booking.admin_texts_rollback(text,text,integer,text)', 'booking.admin_texts_set_class(text,text,text,text)',
    'booking.admin_texts_sync()', 'booking.admin_texts_drift()', 'booking.public_get_site_texts(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array[
    'booking.texts_propose(text,text,text,text,boolean)', 'booking.texts_submit(bigint)', 'booking.texts_withdraw(bigint)', 'booking.texts_list(text,text,text,boolean,integer,integer)',
    'booking.texts_get(text,text)', 'booking.admin_texts_queue(boolean,integer)', 'booking.admin_texts_approve(bigint,text,boolean)', 'booking.admin_texts_publish(bigint)',
    'booking.admin_texts_reject(bigint,text)', 'booking.admin_texts_rollback(text,text,integer,text)', 'booking.admin_texts_set_class(text,text,text,text)',
    'booking.admin_texts_sync()', 'booking.admin_texts_drift()'] loop
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  grant execute on function booking.public_get_site_texts(text) to anon, authenticated;
  grant execute on function booking._text_has(text), booking._text_bot_role(), booking._text_is_service() to authenticated;   -- RLS-politiikat kutsuvat näitä käyttäjän oikeuksilla
end $$;

-- ---------- seed ----------
select booking._texts_register_sources();
