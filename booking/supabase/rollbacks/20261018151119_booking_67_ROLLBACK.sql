-- ROLLBACK booking_67: palauttaa funktiot booking_63/64-tilaan, siirtää botin takaisin text_editor-rooliin ja poistaa uuden roolin, asetuksen, apufunktion ja sarakkeen.
-- Huom: approved_by_kind-sarakkeen tiedot menetetään (audit_log:n vanhat rivit säilyvät).
set local lock_timeout = '5s';
update booking.text_bots set role_code = 'text_editor' where role_code = 'text_editor_approver';
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
      'proposed_by_label', booking._text_user_label(v.author), 'approved_by', v.approved_by, 'approved_by_label', booking._text_user_label(v.approved_by), 'published_by', auth.uid(), 'new_text', v.text));
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
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_texts_rollback(p_key text, p_lang text, p_to_version integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_texts_versions(p_key text, p_lang text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t booking.site_texts;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected', 'texts.manage']);
  select * into t from booking.site_texts where key = lower(btrim(coalesce(p_key, ''))) and lang = lower(btrim(coalesce(p_lang, '')));
  if not found then perform booking._err('not_found', 'Tekstiä ei löydy'); end if;
  return jsonb_build_object('ok', true,
    'text', jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'kind', t.kind, 'max_len', t.max_len, 'placeholders', to_jsonb(t.placeholders), 'text', t.published_text,
             'version', t.published_version, 'status', t.status, 'needs_review', t.needs_review, 'review_note', t.review_note, 'needs_translation', t.needs_translation, 'editable', t.class <> 'locked'),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'version', v.version, 'status', v.status, 'text', v.text, 'base_version', v.base_version, 'protected', v.protected,
                   'escalation', to_jsonb(v.escalation), 'author_kind', v.author_kind, 'proposed_by', booking._text_user_label(v.author), 'proposed_at', v.created_at, 'reason', v.reason, 'note', v.note,
                   'approved_by', booking._text_user_label(v.approved_by), 'approved_at', v.approved_at, 'published_by', booking._text_user_label(v.published_by), 'published_at', v.published_at,
                   'rejected_by', booking._text_user_label(v.rejected_by), 'rejected_at', v.rejected_at,
                   'can_rollback', v.status in ('published', 'superseded') and v.version <> t.published_version and t.class <> 'locked',
                   'is_current', v.version = t.published_version and v.status = 'published') order by v.version desc), '[]'::jsonb)
                   from booking.site_text_versions v where v.text_id = t.id));
end $function$;

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

drop function if exists booking._text_bot_guard();
delete from booking.role_permissions where role_code = 'text_editor_approver';
delete from booking.roles where code = 'text_editor_approver';
delete from booking.settings where key = 'texts_bot_max_approvals_per_day';
alter table booking.site_text_versions drop column if exists approved_by_kind;
