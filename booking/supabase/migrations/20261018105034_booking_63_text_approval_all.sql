-- ============================================================
-- booking_63_text_approval_all: päätös Joonas 18.10.2026: sekä Joonas (admin) että Otto (manager) saavat hyväksyä KAIKKI tekstit, myös suojatut luokat.
--  * manager saa texts.approve_protected (Otto: tavalliset + suojatut + eskaloidut). text_editor (botit) ennallaan: vain texts.propose.
--  * Ei muutu: lukitut kentät (hinnat, hintatekstit, ALV, slug, URL:t: ehdotus/hyväksyntä estetty text_locked), texts.manage (set_class, sync, import: vain admin/service_role).
--  * Audit: audit_log (TEXT_APPROVE/PUBLISH/REJECT/ROLLBACK) kirjaa ehdottajan, hyväksyjän, julkaisijan ja vanhan/uuden tekstin; versioihin rejected_by/rejected_at;
--    admin_texts_audit(key, lang, limit) näyttää historian nimineen.
--  Itse ehdotetun tekstin hyväksyntä: sallittu hyväksyjille (kuten admin aiemminkin); audit näyttää ehdottajan ja hyväksyjän.
-- Rollback: rollbacks/TEXTS_booking_63_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';
insert into booking.role_permissions (role_code, permission) values ('manager', 'texts.approve_protected') on conflict do nothing;
alter table booking.site_text_versions add column if not exists rejected_by uuid, add column if not exists rejected_at timestamptz;
create or replace function booking._text_user_label(p_uid uuid) returns text language sql stable security definer set search_path = '' as $$
  select case when p_uid is null then null else coalesce((select s.name || ' <' || s.email || '>' from booking.staff s where s.user_id = p_uid),
                                                         (select 'botti: ' || b.label from booking.text_bots b where b.user_id = p_uid), p_uid::text) end $$;
create or replace function booking._text_audit(p_action text, p_text_id bigint, p_version integer, p_data jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.site_texts', p_text_id::text || ':' || p_version::text, p_action, null,
          p_data || jsonb_build_object('actor_kind', booking._text_actor_kind(), 'actor_label', booking._text_user_label(auth.uid()))) $$;

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
  update booking.site_texts set published_text = v.text, published_version = v.version, published_at = now(), needs_translation = false,
         needs_review = case when v.approved_by is not null then false else needs_review end,
         review_note = case when v.approved_by is not null then null else review_note end where id = t.id;
  if t.lang in ('fi', 'en') then
    update booking.site_texts set needs_translation = true where key = t.key and lang in ('fi', 'en') and lang <> t.lang and published_version > 0;
  end if;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_PUBLISH', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'protected', v.protected, 'escalation', to_jsonb(v.escalation), 'version_id', v.id, 'proposed_by', v.author, 'proposed_by_kind', v.author_kind,
      'proposed_by_label', booking._text_user_label(v.author), 'approved_by', v.approved_by, 'approved_by_label', booking._text_user_label(v.approved_by), 'published_by', auth.uid(), 'new_text', v.text));
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
  perform booking._text_audit('TEXT_APPROVE', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'protected', v_prot, 'escalation', to_jsonb(v_esc), 'version_id', v.id,
    'proposed_by', v.author, 'proposed_by_kind', v.author_kind, 'proposed_by_label', booking._text_user_label(v.author), 'approved_by', auth.uid(), 'note', nullif(btrim(coalesce(p_note, '')), ''),
    'old_text', t.published_text, 'new_text', v.text, 'publish', coalesce(p_publish, true)));
  if coalesce(p_publish, true) then perform booking._text_publish(v.id); else perform booking._text_refresh(t.id); end if;
  return jsonb_build_object('ok', true, 'version_id', v.id, 'status', case when coalesce(p_publish, true) then 'published' else 'approved' end, 'protected', v_prot);
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
  update booking.site_text_versions set status = 'rejected', note = nullif(btrim(coalesce(p_note, '')), ''), rejected_by = auth.uid(), rejected_at = now() where id = v.id;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_REJECT', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'protected', v.protected, 'version_id', v.id, 'proposed_by', v.author, 'proposed_by_kind', v.author_kind,
    'proposed_by_label', booking._text_user_label(v.author), 'rejected_by', auth.uid(), 'note', nullif(btrim(coalesce(p_note, '')), ''), 'rejected_text', v.text));
  return jsonb_build_object('ok', true, 'version_id', v.id, 'status', 'rejected');
end $$;

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
  perform booking._text_audit('TEXT_ROLLBACK', t.id, v_ver, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'protected', v_prot, 'escalation', to_jsonb(v_esc), 'to_version', p_to_version, 'approved_by', auth.uid(),
    'old_text', t.published_text, 'new_text', tv.text, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  perform booking._text_publish(v_id);
  return jsonb_build_object('ok', true, 'version_id', v_id, 'version', v_ver, 'status', 'published', 'protected', v_prot);
end $$;

-- kuka ehdotti, hyväksyi, julkaisi tai hylkäsi mitäkin (versiohistoria nimineen); vain hyväksyjät/ylläpito
create or replace function booking.admin_texts_audit(p_key text default null, p_lang text default null, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected', 'texts.manage']);
  return jsonb_build_object('ok', true, 'items', (select coalesce(jsonb_agg(q.item order by q.act desc), '[]'::jsonb) from (
    select greatest(v.created_at, coalesce(v.approved_at, v.created_at), coalesce(v.published_at, v.created_at), coalesce(v.rejected_at, v.created_at)) act,
           jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'version', v.version, 'status', v.status, 'protected', v.protected, 'escalation', to_jsonb(v.escalation),
             'text', v.text, 'reason', v.reason, 'note', v.note,
             'proposed_by', booking._text_user_label(v.author), 'proposed_by_kind', v.author_kind, 'proposed_at', v.created_at,
             'approved_by', booking._text_user_label(v.approved_by), 'approved_at', v.approved_at,
             'published_by', booking._text_user_label(v.published_by), 'published_at', v.published_at,
             'rejected_by', booking._text_user_label(v.rejected_by), 'rejected_at', v.rejected_at) item
      from booking.site_text_versions v join booking.site_texts t on t.id = v.text_id
     where (p_key is null or t.key = lower(btrim(p_key))) and (p_lang is null or t.lang = lower(btrim(p_lang)))
     order by greatest(v.created_at, coalesce(v.approved_at, v.created_at), coalesce(v.published_at, v.created_at), coalesce(v.rejected_at, v.created_at)) desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500)) q));
end $$;
revoke all on function booking.admin_texts_audit(text, text, integer) from public, anon, authenticated;
grant execute on function booking.admin_texts_audit(text, text, integer) to authenticated, service_role;
revoke all on function booking._text_user_label(uuid) from public, anon, authenticated;
