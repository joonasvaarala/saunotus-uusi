-- Rollback booking_237 (20261102140000_booking_237_stale_en_fix.sql).
-- Palauttaa funktioiden rungot täsmälleen booking_237:ää edeltävään määrittelyyn:
--   booking._text_publish, booking.texts_propose, booking.admin_texts_approve: booking_67
--   booking._text_source_changed: booking_61
--   booking.svc_texts_stale_en, booking.svc_set_product_text_en: booking_235
-- Palauttaa kertakorjauksen needs_translation-liput ja kahden avaimen englannin published_at -arvot.
-- Ei muuta tekstisisältöä, hintoja, ALV:tä, slugia eikä URL:eja.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

CREATE OR REPLACE FUNCTION booking.texts_propose(p_key text, p_lang text, p_text text, p_reason text DEFAULT NULL::text, p_draft boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t booking.site_texts; v_esc text[]; v_prot boolean; v_ver int; v_id bigint; v_max int; v_n int;
begin
  perform booking._text_perm('texts.propose');
  t := booking._text_row(p_key, p_lang, true);
  if t.class = 'locked' then perform booking._err('text_locked', 'Tämä teksti on lukittu (hinnat, ALV, URL:t ja vastaavat); sitä ei voi ehdottaa'); end if;
  perform booking._text_validate(t.class, t.kind, t.max_len, t.placeholders, p_text);
  if p_text = t.published_text then perform booking._err('no_change', 'Teksti ei eroa julkaistusta'); end if;
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
end $function$;

CREATE OR REPLACE FUNCTION booking._text_publish(p_version_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if t.lang in ('fi', 'en') then
    update booking.site_texts set needs_translation = true where key = t.key and lang in ('fi', 'en') and lang <> t.lang and published_version > 0;
  end if;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_PUBLISH', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'protected', v.protected, 'escalation', to_jsonb(v.escalation), 'version_id', v.id, 'proposed_by', v.author, 'proposed_by_kind', v.author_kind,
      'proposed_by_label', booking._text_user_label(v.author), 'approved_by', v.approved_by, 'approved_by_label', booking._text_user_label(v.approved_by), 'approved_by_kind', v.approved_by_kind, 'self_approved', (v.approved_by is not null and v.author is not distinct from v.approved_by), 'published_by', auth.uid(), 'new_text', v.text));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_texts_approve(p_version_id bigint, p_note text DEFAULT NULL::text, p_publish boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

create or replace function booking._text_source_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
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
    if r.lang in ('fi', 'en') then update booking.site_texts set needs_translation = true where key = r.key and lang in ('fi', 'en') and lang <> r.lang and published_version > 0; end if;
    perform booking._text_refresh(r.id);
    perform booking._text_audit('TEXT_DIRECT_EDIT', r.id, v_ver, jsonb_build_object('key', r.key, 'table', tg_table_schema || '.' || tg_table_name));
  end loop;
  return null;
end $$;

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
    select t.key, t.source_table, t.source_pk, t.source_column, t.published_text, t.published_at,
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
           fi.published_at as fi_at,
           en.published_at as en_at,
           case
             when en.id is null or btrim(coalesce(en.published_text, '')) = '' or coalesce(en.published_version, 0) = 0 then 'missing'
             when en.published_at is null or fi.published_at is null or en.published_at < fi.published_at then 'older'
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
  select count(*) into v_total from all_rows;

  with fi as (
    select t.key, t.source_table, t.source_pk, t.source_column, t.published_text, t.published_at,
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
           fi.published_at as fi_at,
           en.published_at as en_at,
           case
             when en.id is null or btrim(coalesce(en.published_text, '')) = '' or coalesce(en.published_version, 0) = 0 then 'missing'
             when en.published_at is null or fi.published_at is null or en.published_at < fi.published_at then 'older'
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
  select coalesce(jsonb_agg(jsonb_build_object(
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
    into v_items
    from (
      select a.*,
             case a.reason when 'missing' then 0 when 'unmirrored' then 1 else 2 end as ord
        from all_rows a
       order by case a.reason when 'missing' then 0 when 'unmirrored' then 1 else 2 end,
                a.fi_at nulls first, a.key
       limit v_lim
    ) q;

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
  v_fresh := t.published_at is not null and fi.published_at is not null and t.published_at >= fi.published_at
             and btrim(t.published_text) <> '';
  if p_text is not distinct from t.published_text and v_fresh then
    perform booking._err('no_change', 'Teksti ei eroa julkaistusta');
  end if;
  if p_text is distinct from t.published_text then
    v_esc := booking._text_escalation(v_fi, p_text);
    if v_esc && array['link', 'currency', 'email', 'phone'] then
      perform booking._err('facts_changed', 'Englanninkielinen teksti ei saa muuttaa linkkejä, hintoja, puhelinnumeroita tai sähköposteja');
    end if;
  else
    v_esc := '{}';
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

revoke all on function booking.svc_texts_stale_en(integer) from public, anon, authenticated;
grant execute on function booking.svc_texts_stale_en(integer) to service_role;

revoke all on function booking.svc_set_product_text_en(bigint, text, text, text) from public, anon, authenticated;
grant execute on function booking.svc_set_product_text_en(bigint, text, text, text) to service_role;

comment on function booking.svc_texts_stale_en(integer) is
  'booking_235: service_role listaa suomen tekstit, joiden englanti puuttuu tai on vanhempi kuin suomen viimeisin julkaisu. Mukana tuotteen site_texts-rivit ja peilaamattomat kb.products-kentät.';

comment on function booking.svc_set_product_text_en(bigint, text, text, text) is
  'booking_235: service_role kirjoittaa vain tuotteen *_en-tekstin (name, description, short_description, duration_text). Ei hintaa, ALV:tä, URLia, slugia, active-lippua eikä suomea. Audit SVC_SET_PRODUCT_TEXT_EN.';

-- Englannin julkaisuaika takaisin (vain aikaleima, ei tekstiä).
update booking.site_texts en
   set published_at = case when e ->> 'published_at' is null then null else (e ->> 'published_at')::timestamptz end
  from booking.settings s
  cross join lateral jsonb_array_elements(s.value) e
 where s.key = 'booking_237_en_timestamp_touch'
   and en.id = (e ->> 'id')::bigint
   and en.lang = 'en';

update booking.site_text_versions v
   set published_at = case when e ->> 'version_published_at' is null then null else (e ->> 'version_published_at')::timestamptz end
  from booking.settings s
  cross join lateral jsonb_array_elements(s.value) e
 where s.key = 'booking_237_en_timestamp_touch'
   and e ->> 'version_id' is not null
   and v.id = (e ->> 'version_id')::bigint;

-- Suomen needs_translation takaisin trueksi niille riveille, joilta migraatio sen nollasi.
update booking.site_texts fi
   set needs_translation = true
 where fi.lang = 'fi'
   and not fi.needs_translation
   and fi.id in (
     select (x)::bigint
       from booking.settings s
       cross join lateral jsonb_array_elements_text(s.value) x
      where s.key = 'booking_237_needs_translation_reset'
   );

delete from booking.settings where key in ('booking_237_en_timestamp_touch', 'booking_237_needs_translation_reset');

drop function if exists booking._text_clear_fi_flags_when_en_current();
drop function if exists booking._text_touch_en_current(bigint);
drop function if exists booking._text_effective_at(bigint);
