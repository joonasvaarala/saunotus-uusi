-- booking_237: käännöslistan korjaus (booking_235 svc_texts_stale_en / svc_set_product_text_en).
-- booking_235 on jo tuotannossa. Tätä tiedostoa ei ajeta sen päälle muokkaamalla vanhaa migraatiota.
--
-- 1) svc_texts_stale_en piti riviä vanhana, jos suomen TAI englannin site_texts.published_at on NULL.
--    _texts_reg lisää lähderivit ilman published_at:tä (julkaisuhetki on site_text_versions.published_at
--    tai muuten created_at). NULL ei saa yksin tehdä rivistä vanhaa.
--    Vertailu: coalesce(site_texts.published_at, julkaistun version published_at, created_at).
--    updated_at ei kelpaa: needs_translation-päivitys laukaisee set_updated_at-triggerin ja
--    siirtäisi suomen rivin englannin julkaisun jälkeen.
--
-- 2) booking._text_publish ja triggerifunktio booking._text_source_changed nostivat toisen kielen
--    needs_translation-lipun. Englannin julkaisu (admin_texts_approve tai svc_set_product_text_en,
--    molemmat kutsuvat _text_publishia) merkitsi siis SUOMEN rivin käännettäväksi. Suunta oli väärä.
--    Englannin julkaisu nollaa suomen lipun. Suomen muutos nostaa englannin rivin lipun
--    (käännös vanhentui) ja jättää suomen lipun falseksi: juuri julkaistu lähde ei ole käännettävä
--    (sama kuin t60 C27).
--    Kertakorjaus: needs_translation = false niille suomen riveille, joiden englanti on ei-tyhjä
--    eikä vanhempi samalla vertailulla. Suomen tekstiä ei muuteta.
--
-- 3) ui.gift.marketing ja ui.shop.consent_marketing jäivät listalle, koska suomi julkaistiin
--    myöhemmin (booking_65) ja sama englanti hylätään texts_propose-kutsussa no_change-virheenä.
--    Identtinen englanti, joka on vertailun mukaan vanha, päivittää vain englannin julkaisuajan
--    (texts_propose, admin_texts_approve ja svc_set_product_text_en). Lista ei näytä riviä,
--    jonka englanti on tällä vertailulla ajan tasalla. Näille kahdelle avaimelle julkaisuaika
--    päivitetään kerran, koska kääntäjän ajo 2.11.2026 totesi englannin jo oikeaksi.
--    Vain aikaleima, ei tekstiä.
--
-- Ei md5-vartijaa: _text_publish, _text_source_changed, texts_propose ja admin_texts_approve
-- eivät ole myöhempien migraatioiden md5(pg_get_functiondef)-listoilla, eikä booking_235
-- pinnannut svc_*-funktioita. UNVERIFIED_-paikkoja ei siksi tarvita.
-- Hintoja, ALV:tä, slugia, URL:eja eikä suomen tai englannin tekstiä ei muuteta.
-- SECURITY DEFINER, search_path='', execute vain service_role (uudet ja korvatut svc-funktiot).
-- Rollback: rollbacks/20261102140000_booking_237_ROLLBACK.sql
-- Testi: tests/t237_stale_en_fix.sql

set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function booking._text_effective_at(p_text_id bigint)
returns timestamptz
language sql
stable
security definer
set search_path to ''
as $fn$
  select coalesce(
    t.published_at,
    (select v.published_at
       from booking.site_text_versions v
      where v.text_id = t.id
        and v.version = t.published_version
        and v.published_at is not null
      order by v.id desc
      limit 1),
    t.created_at)
    from booking.site_texts t
   where t.id = p_text_id
$fn$;

comment on function booking._text_effective_at(bigint) is
  'booking_237: tekstin vertailuaika. published_at, muuten julkaistun version published_at, muuten created_at. Ei updated_at.';

create or replace function booking._text_touch_en_current(p_en_id bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  t booking.site_texts;
  v_at timestamptz := clock_timestamp();
begin
  select * into t from booking.site_texts where id = p_en_id and lang = 'en' for update;
  if not found then
    return;
  end if;
  update booking.site_texts
     set published_at = v_at,
         needs_translation = false
   where id = t.id;
  update booking.site_text_versions
     set published_at = v_at
   where text_id = t.id
     and version = t.published_version
     and status = 'published';
  update booking.site_texts
     set needs_translation = false
   where key = t.key
     and lang = 'fi'
     and needs_translation;
end
$fn$;

comment on function booking._text_touch_en_current(bigint) is
  'booking_237: sama englanti kuin julkaistu. Päivittää vain julkaisuajan ja nollaa suomen needs_translation-lipun. Ei muuta tekstiä.';

create or replace function booking._text_clear_fi_flags_when_en_current()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  ids jsonb;
begin
  with cand as (
    select fi.id
      from booking.site_texts fi
      join booking.site_texts en on en.key = fi.key and en.lang = 'en'
     where fi.lang = 'fi'
       and fi.needs_translation
       and btrim(en.published_text) <> ''
       and coalesce(en.published_version, 0) > 0
       and not (booking._text_effective_at(en.id) < booking._text_effective_at(fi.id))
  ), upd as (
    update booking.site_texts fi
       set needs_translation = false
      from cand
     where fi.id = cand.id
       and fi.lang = 'fi'
       and fi.needs_translation
    returning fi.id
  )
  select coalesce(jsonb_agg(id order by id), '[]'::jsonb) into ids from upd;
  return ids;
end
$fn$;

comment on function booking._text_clear_fi_flags_when_en_current() is
  'booking_237: nollaa suomen needs_translation-lipun, kun englanti on ei-tyhjä eikä vanhempi. Ei muuta tekstiä. Palauttaa korjatut id:t.';

-- Suomen julkaisu merkitsee englannin käännettäväksi. Englannin julkaisu nollaa suomen lipun.
create or replace function booking._text_publish(p_version_id bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $fn$
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
  update booking.site_texts set published_text = v.text, published_version = v.version, published_at = now(), needs_translation = false,
         needs_review = case when v.approved_by is not null then false else needs_review end,
         review_note = case when v.approved_by is not null then null else review_note end where id = t.id;
  if t.lang = 'fi' then
    update booking.site_texts set needs_translation = true
     where key = t.key and lang = 'en' and published_version > 0;
  elsif t.lang = 'en' then
    update booking.site_texts set needs_translation = false
     where key = t.key and lang = 'fi' and needs_translation;
  end if;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_PUBLISH', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'protected', v.protected, 'escalation', to_jsonb(v.escalation), 'version_id', v.id, 'proposed_by', v.author, 'proposed_by_kind', v.author_kind,
      'proposed_by_label', booking._text_user_label(v.author), 'approved_by', v.approved_by, 'approved_by_label', booking._text_user_label(v.approved_by), 'approved_by_kind', v.approved_by_kind, 'self_approved', (v.approved_by is not null and v.author is not distinct from v.approved_by), 'published_by', auth.uid(), 'new_text', v.text));
end
$fn$;

create or replace function booking._text_source_changed()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
declare r booking.site_texts; v_new text; v_ver int; v_pk text := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'code', to_jsonb(new) ->> 'product_id');
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
    if r.lang = 'fi' then
      update booking.site_texts set needs_translation = true
       where key = r.key and lang = 'en' and published_version > 0;
    elsif r.lang = 'en' then
      update booking.site_texts set needs_translation = false
       where key = r.key and lang = 'fi' and needs_translation;
    end if;
    perform booking._text_refresh(r.id);
    perform booking._text_audit('TEXT_DIRECT_EDIT', r.id, v_ver, jsonb_build_object('key', r.key, 'table', tg_table_schema || '.' || tg_table_name));
  end loop;
  return null;
end
$fn$;

create or replace function booking.texts_propose(p_key text, p_lang text, p_text text, p_reason text default null, p_draft boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare t booking.site_texts; v_esc text[]; v_prot boolean; v_ver int; v_id bigint; v_max int; v_n int;
begin
  perform booking._text_perm('texts.propose');
  t := booking._text_row(p_key, p_lang, true);
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu (hinnat, ALV, URL:t ja vastaavat); sitä ei voi ehdottaa'); end if;
  perform booking._text_validate(t.class, t.kind, t.max_len, t.placeholders, p_text);
  if p_text = t.published_text then
    -- Sama englanti, mutta suomea uudempi julkaisuaika puuttuu: päivitä vain aika, jotta lista ei jää jumiin.
    if t.lang = 'en' and not coalesce(p_draft, false) and exists (
         select 1 from booking.site_texts fi
          where fi.key = t.key and fi.lang = 'fi' and btrim(fi.published_text) <> ''
            and booking._text_effective_at(t.id) < booking._text_effective_at(fi.id)) then
      perform booking._text_touch_en_current(t.id);
      perform booking._text_audit('TEXT_EN_REFRESH', t.id, t.published_version,
        jsonb_build_object('key', t.key, 'lang', t.lang, 'unchanged', true, 'via', 'texts_propose'));
      return jsonb_build_object(
        'ok', true,
        'version_id', (select v.id from booking.site_text_versions v
                        where v.text_id = t.id and v.version = t.published_version and v.status = 'published'
                        order by v.id desc limit 1),
        'version', t.published_version,
        'status', 'published',
        'unchanged', true,
        'refreshed', true,
        'protected', false,
        'escalation', '[]'::jsonb,
        'approver', 'texts.approve');
    end if;
    perform booking._err('no_change', 'Teksti ei eroa julkaistusta');
  end if;
  if booking._text_actor_kind() = 'bot' or not (booking._text_has('texts.approve') or booking._text_has('texts.approve_protected')) then
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
end
$fn$;

create or replace function booking.admin_texts_approve(p_version_id bigint, p_note text default null, p_publish boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare v booking.site_text_versions; t booking.site_texts; v_esc text[]; v_prot boolean;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']);
  select * into v from booking.site_text_versions where id = p_version_id for update;
  if not found then perform booking._err('not_found', 'Versiota ei löydy'); end if;
  select * into t from booking.site_texts where id = v.text_id for update;
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu'); end if;
  -- Sama englanti kuin jo julkaistu: ei uutta versiota, vain julkaisuaika. Suojausluokka ei estä, koska teksti ei muutu.
  if t.lang = 'en' and v.text is not distinct from t.published_text and v.status in ('proposed', 'approved', 'published') then
    perform booking._text_touch_en_current(t.id);
    if v.status in ('proposed', 'approved') then
      update booking.site_text_versions
         set status = 'superseded',
             note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'sama englanti kuin julkaistu; julkaisuaika päivitetty')
       where id = v.id;
      perform booking._text_refresh(t.id);
    end if;
    perform booking._text_audit('TEXT_EN_REFRESH', t.id, t.published_version,
      jsonb_build_object('key', t.key, 'lang', t.lang, 'unchanged', true, 'via', 'admin_texts_approve', 'version_id', v.id));
    return jsonb_build_object('ok', true, 'version_id', v.id, 'status', 'published', 'unchanged', true, 'refreshed', true, 'protected', false);
  end if;
  if v.status <> 'proposed' then perform booking._err('bad_state', 'Vain ehdotetun version voi hyväksyä (tila: ' || v.status || ')'); end if;
  if v.base_version <> t.published_version then
    update booking.site_text_versions set status = 'stale', note = 'vanhentunut' where id = v.id; perform booking._text_refresh(t.id);
    perform booking._err('stale_base', 'Julkaistu teksti on muuttunut ehdotuksen jälkeen; ehdota uudelleen');
  end if;
  v_esc := booking._text_escalation(t.published_text, v.text); v_prot := t.class = 'protected' or cardinality(v_esc) > 0;
  perform booking._text_need_approve(v_prot);
  perform booking._text_bot_guard();
  if v.author is not null and v.author = auth.uid() and not booking._text_has('texts.approve_protected') and not booking._text_has('texts.approve_own') then
    perform booking._err('self_approval', 'Omaa ehdotusta ei voi hyväksyä itse');
  end if;
  perform booking._text_validate(t.class, t.kind, t.max_len, t.placeholders, v.text);
  update booking.site_text_versions set status = 'approved', approved_by = auth.uid(), approved_by_kind = booking._text_actor_kind(), approved_at = now(), note = nullif(btrim(coalesce(p_note, '')), ''), escalation = v_esc, protected = v_prot where id = v.id;
  perform booking._text_audit('TEXT_APPROVE', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'protected', v_prot, 'escalation', to_jsonb(v_esc), 'version_id', v.id,
    'proposed_by', v.author, 'proposed_by_kind', v.author_kind, 'proposed_by_label', booking._text_user_label(v.author), 'approved_by', auth.uid(), 'approved_by_kind', booking._text_actor_kind(), 'approved_by_label', booking._text_user_label(auth.uid()), 'self_approved', (v.author is not null and v.author = auth.uid()), 'note', nullif(btrim(coalesce(p_note, '')), ''),
    'old_text', t.published_text, 'new_text', v.text, 'publish', coalesce(p_publish, true)));
  if coalesce(p_publish, true) then perform booking._text_publish(v.id); else perform booking._text_refresh(t.id); end if;
  return jsonb_build_object('ok', true, 'version_id', v.id, 'status', case when coalesce(p_publish, true) then 'published' else 'approved' end, 'protected', v_prot);
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
    select t.id, t.key, t.source_table, t.source_pk, t.source_column, t.published_text,
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
           booking._text_effective_at(fi.id) as fi_at,
           booking._text_effective_at(en.id) as en_at,
           case
             when en.id is null or btrim(coalesce(en.published_text, '')) = '' or coalesce(en.published_version, 0) = 0 then 'missing'
             when booking._text_effective_at(en.id) < booking._text_effective_at(fi.id) then 'older'
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
          ('description', 'description', p.description, p.description_en, 4000),
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
  select c.n, c.items
    into v_total, v_items
    from (
      select (select count(*)::int from all_rows) as n,
             (select coalesce(jsonb_agg(jsonb_build_object(
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
                from (
                  select a.*,
                         case a.reason when 'missing' then 0 when 'unmirrored' then 1 else 2 end as ord
                    from all_rows a
                   order by case a.reason when 'missing' then 0 when 'unmirrored' then 1 else 2 end,
                            a.fi_at nulls first, a.key
                   limit v_lim
                ) q) as items
    ) c;

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
  v_en_at timestamptz;
  v_fi_at timestamptz;
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
  v_en_at := booking._text_effective_at(t.id);
  v_fi_at := case when fi.id is null then null else booking._text_effective_at(fi.id) end;
  v_fresh := btrim(coalesce(t.published_text, '')) <> ''
             and (v_fi_at is null or (v_en_at is not null and v_en_at >= v_fi_at));
  if p_text is not distinct from t.published_text then
    if v_fresh then
      perform booking._err('no_change', 'Teksti ei eroa julkaistusta');
    end if;
    perform booking._text_touch_en_current(t.id);
    if (to_jsonb(p) ->> v_col) is distinct from p_text then
      perform set_config('booking.text_apply', 'on', true);
      execute format('update kb.products set %I = $1 where id = $2', v_col) using p_text, p_product_id;
      perform set_config('booking.text_apply', '', true);
    end if;
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
      jsonb_build_object('field', v_field, 'column', v_col, 'key', t.key, 'text', p_text, 'actor', v_actor, 'unchanged', true, 'refreshed', true)
    );
    return jsonb_build_object(
      'ok', true,
      'product_id', p_product_id,
      'field', v_field,
      'key', t.key,
      'text', p_text,
      'unchanged', true,
      'refreshed', true
    );
  end if;
  v_esc := booking._text_escalation(v_fi, p_text);
  if v_esc && array['link', 'currency', 'email', 'phone'] then
    perform booking._err('facts_changed', 'Englanninkielinen teksti ei saa muuttaa linkkejä, hintoja, puhelinnumeroita tai sähköposteja');
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

revoke all on function booking._text_effective_at(bigint) from public, anon, authenticated;
grant execute on function booking._text_effective_at(bigint) to service_role;

revoke all on function booking._text_touch_en_current(bigint) from public, anon, authenticated;
grant execute on function booking._text_touch_en_current(bigint) to service_role;

revoke all on function booking._text_clear_fi_flags_when_en_current() from public, anon, authenticated;
grant execute on function booking._text_clear_fi_flags_when_en_current() to service_role;

revoke all on function booking.svc_texts_stale_en(integer) from public, anon, authenticated;
grant execute on function booking.svc_texts_stale_en(integer) to service_role;

revoke all on function booking.svc_set_product_text_en(bigint, text, text, text) from public, anon, authenticated;
grant execute on function booking.svc_set_product_text_en(bigint, text, text, text) to service_role;

comment on function booking.svc_texts_stale_en(integer) is
  'booking_237: service_role listaa suomen tekstit, joiden englanti puuttuu tai on vanhempi. NULL published_at ei tee rivistä vanhaa; vertailu käyttää julkaistun version aikaa tai created_at. Identtinen ajan tasalla oleva englanti ei näy.';

comment on function booking.svc_set_product_text_en(bigint, text, text, text) is
  'booking_237: service_role kirjoittaa vain tuotteen *_en-tekstin. Sama teksti päivittää julkaisuajan, jos englanti on suomea vanhempi. Ei hintaa, ALV:tä, URLia, slugia, active-lippua eikä suomea.';

-- Kertakorjaus. Tekstisisältö ja hinnat varmennetaan ennen/jälkeen.
do $fix$
declare
  v_txt_before text;
  v_txt_after text;
  v_price_before text;
  v_price_after text;
  v_touch jsonb;
  v_flags jsonb;
begin
  select md5(coalesce(string_agg(id::text || ':' || md5(published_text), ',' order by id), ''))
    into v_txt_before
    from booking.site_texts;
  select md5(coalesce(string_agg(
           id::text || ':' || coalesce(price::text, '') || ':' || coalesce(vat_rate::text, '') || ':' ||
           coalesce(slug, '') || ':' || coalesce(booking_url, '') || ':' || coalesce(active::text, '') || ':' ||
           md5(coalesce(name, '')) || ':' || md5(coalesce(description, '')) || ':' ||
           md5(coalesce(short_description, '')) || ':' || md5(coalesce(duration_text, '')) || ':' ||
           md5(coalesce(price_text, '')), ',' order by id), ''))
    into v_price_before
    from kb.products;

  if not exists (select 1 from booking.settings where key = 'booking_237_en_timestamp_touch') then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', en.id,
             'published_at', en.published_at,
             'version_id', v.id,
             'version_published_at', v.published_at
           ) order by en.id), '[]'::jsonb)
      into v_touch
      from booking.site_texts en
      join booking.site_texts fi on fi.key = en.key and fi.lang = 'fi'
      left join booking.site_text_versions v
        on v.text_id = en.id and v.version = en.published_version and v.status = 'published'
     where en.lang = 'en'
       and en.key in ('ui.gift.marketing', 'ui.shop.consent_marketing')
       and btrim(en.published_text) <> ''
       and booking._text_effective_at(en.id) < booking._text_effective_at(fi.id);
    update booking.site_texts en
       set published_at = clock_timestamp()
     where en.id in (select (e ->> 'id')::bigint from jsonb_array_elements(v_touch) e);
    update booking.site_text_versions v
       set published_at = clock_timestamp()
     where v.id in (
       select (e ->> 'version_id')::bigint
         from jsonb_array_elements(v_touch) e
        where e ->> 'version_id' is not null);
    insert into booking.settings(key, value, description, is_public)
    values ('booking_237_en_timestamp_touch', v_touch,
            'booking_237: ui.gift.marketing ja ui.shop.consent_marketing, englannin published_at ennen aikaleiman päivitystä.',
            false);
    raise notice 'booking_237: julkaisuaika päivitetty % englannin riville', jsonb_array_length(v_touch);
  end if;

  if not exists (select 1 from booking.settings where key = 'booking_237_needs_translation_reset') then
    v_flags := booking._text_clear_fi_flags_when_en_current();
    insert into booking.settings(key, value, description, is_public)
    values ('booking_237_needs_translation_reset', v_flags,
            'booking_237: suomen site_texts.id, joilta needs_translation nollattiin koska englanti ei ole vanhempi.',
            false);
    raise notice 'booking_237: needs_translation nollattu % suomen riviltä', jsonb_array_length(v_flags);
  end if;

  select md5(coalesce(string_agg(id::text || ':' || md5(published_text), ',' order by id), ''))
    into v_txt_after
    from booking.site_texts;
  select md5(coalesce(string_agg(
           id::text || ':' || coalesce(price::text, '') || ':' || coalesce(vat_rate::text, '') || ':' ||
           coalesce(slug, '') || ':' || coalesce(booking_url, '') || ':' || coalesce(active::text, '') || ':' ||
           md5(coalesce(name, '')) || ':' || md5(coalesce(description, '')) || ':' ||
           md5(coalesce(short_description, '')) || ':' || md5(coalesce(duration_text, '')) || ':' ||
           md5(coalesce(price_text, '')), ',' order by id), ''))
    into v_price_after
    from kb.products;
  if v_txt_before is distinct from v_txt_after then
    raise exception 'booking_237: sivutekstin sisältö muuttui; mitään ei saa jäädä voimaan';
  end if;
  if v_price_before is distinct from v_price_after then
    raise exception 'booking_237: tuotteen hinta, ALV, slug, URL tai suomi muuttui; mitään ei saa jäädä voimaan';
  end if;
end
$fix$;
