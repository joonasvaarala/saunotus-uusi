-- ============================================================
-- booking_62_text_import: vapaiden tekstiavainten (ei lähdetaulua: käyttöliittymä-, sivu- ja lomaketekstit) tuonti tekstijärjestelmään.
--  * booking.admin_texts_import(p_items jsonb): luo puuttuvat rivit julkaistuna v1:nä (ei ylikirjoita olemassa olevia; muutokset kulkevat ehdotus -> hyväksyntä). Oikeus texts.manage (admin / service_role).
--  * public_get_site_texts palauttaa nyt myös placeholders (build täyttää esim. {{price:7}}).
--  Hintoja, julkaisua tai asiakasnäkyvää sisältöä ei muuteta (tuonti ei tee mitään ennen kuin sitä kutsutaan).
-- Rollback: rollbacks/TEXTS_booking_62_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

create or replace function booking.admin_texts_import(p_items jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare e jsonb; v_key text; v_lang text; v_class text; v_kind text; v_max int; v_ph text[]; v_text text; v_id bigint; v_res jsonb := '[]'::jsonb; n_new int := 0; n_exist int := 0; v_status text; v_msg text; v_detail text;
begin
  perform booking._text_perm('texts.manage');
  if p_items is null or jsonb_typeof(p_items) <> 'array' then perform booking._err('invalid_items', 'p_items pitää olla taulukko'); end if;
  if jsonb_array_length(p_items) > 500 then perform booking._err('too_many', 'Enintään 500 riviä / kutsu'); end if;
  for e in select * from jsonb_array_elements(p_items) loop
    begin  -- yksi virheellinen rivi ei kaada muita
      v_key := lower(btrim(coalesce(e ->> 'key', ''))); v_lang := lower(btrim(coalesce(e ->> 'lang', ''))); v_class := coalesce(nullif(e ->> 'class', ''), 'normal');
      v_kind := coalesce(nullif(e ->> 'kind', ''), 'plain'); v_max := coalesce(nullif(e ->> 'max_len', '')::int, 4000); v_text := e ->> 'text';
      v_ph := coalesce((select array_agg(distinct x order by x) from jsonb_array_elements_text(coalesce(e -> 'placeholders', '[]'::jsonb)) x), '{}');
      if v_key !~ '^[a-z0-9_]+(\.[a-z0-9_-]+)+$' or char_length(v_key) > 120 then perform booking._err('invalid_key', 'Virheellinen avain'); end if;
      if v_key ~ '^(product|faq|policy|addon|option|giftpkg|schedule|location|hours|event|business|timeline|product_voucher)\.[0-9a-z_-]+\.' then perform booking._err('reserved_key', 'Avainprefiksi on varattu lähdetaulupohjaisille teksteille'); end if;
      if v_lang not in ('fi', 'en') then perform booking._err('invalid_lang', 'Kieli fi tai en'); end if;
      if v_class not in ('normal', 'protected') then perform booking._err('invalid_class', 'Luokka normal tai protected (locked-rivit vain lähdetauluista)'); end if;
      if v_kind not in ('plain', 'lite') then perform booking._err('invalid_kind', 'kind plain tai lite'); end if;
      if v_max not between 1 and 100000 then perform booking._err('invalid_max_len', 'max_len 1–100000'); end if;
      perform booking._text_validate(v_class, v_kind, v_max, v_ph, v_text);
      if exists (select 1 from booking.site_texts where key = v_key and lang = v_lang) then
        n_exist := n_exist + 1; v_res := v_res || jsonb_build_array(jsonb_build_object('key', v_key, 'lang', v_lang, 'result', 'exists'));
      else
        insert into booking.site_texts(key, lang, class, kind, max_len, placeholders, published_text, published_version, latest_version, status, published_at)
        values (v_key, v_lang, v_class, v_kind, v_max, v_ph, v_text, 1, 1, 'published', now()) returning id into v_id;
        insert into booking.site_text_versions(text_id, version, text, status, base_version, author, author_kind, author_label, reason, published_by, published_at, escalation, protected)
        values (v_id, 1, v_text, 'published', 0, auth.uid(), booking._text_actor_kind(), coalesce(auth.uid()::text, 'sql'), coalesce(nullif(btrim(coalesce(e ->> 'reason', '')), ''), 'Tuonti (admin_texts_import)'), auth.uid(), now(), '{}', v_class = 'protected');
        perform booking._text_audit('TEXT_IMPORT', v_id, 1, jsonb_build_object('key', v_key, 'lang', v_lang, 'class', v_class));
        n_new := n_new + 1; v_res := v_res || jsonb_build_array(jsonb_build_object('key', v_key, 'lang', v_lang, 'result', 'created'));
      end if;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      v_res := v_res || jsonb_build_array(jsonb_build_object('key', e ->> 'key', 'lang', e ->> 'lang', 'result', 'error', 'code', v_detail, 'message', v_msg));
    end;
  end loop;
  return jsonb_build_object('ok', true, 'created', n_new, 'existing', n_exist, 'errors', jsonb_array_length(v_res) - n_new - n_exist, 'items', v_res);
end $$;
revoke all on function booking.admin_texts_import(jsonb) from public, anon, authenticated;
grant execute on function booking.admin_texts_import(jsonb) to authenticated, service_role;

create or replace function booking.public_get_site_texts(p_lang text default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'generated_at', now(), 'texts', coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'lang', t.lang, 'text', t.published_text, 'version', t.published_version, 'placeholders', to_jsonb(t.placeholders))
                                                                                           order by t.key, t.lang), '[]'::jsonb))
    from booking.site_texts t
   where t.published_version > 0 and t.published_text <> '' and t.class <> 'locked' and (p_lang is null or t.lang = lower(btrim(p_lang))) $$;
