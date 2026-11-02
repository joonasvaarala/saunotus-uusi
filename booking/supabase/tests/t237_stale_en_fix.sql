-- t237: booking_237 käännöslistan korjaus (migraatio 20261102122300, tuotannon versio).
-- RIIPPUVUUS: fixtures/10_test_helpers.sql on ajettava ensin. Testi käyttää test.login / test.logout -apureita
-- (skeema "test"); ilman niitä ajo kaatuu virheeseen 'schema "test" does not exist'. Lisäksi kb-mock, jotta tuote 7 on olemassa.
-- Ajo (psql, paikallinen PG17 tai testikanta, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t237_stale_en_fix.sql
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" ja rollback kumoavat kaiken. Ei tuotantoon.
begin;
do $pre$ begin
  if to_regnamespace('test') is null or to_regprocedure('test.login(uuid,text)') is null then
    raise exception 't237: fixtures/10_test_helpers.sql puuttuu (skeema test / test.login). Aja se ensin, ks. otsikko.';
  end if;
end $pre$;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t237.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t237.log', coalesce(current_setting('t237.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return coalesce(d, sqlstate);
end $$;

create function pg_temp.pair(
  p_key text, p_fi text, p_en text,
  p_fi_at timestamptz, p_en_at timestamptz,
  p_fi_created timestamptz, p_en_created timestamptz,
  p_fi_ver_at timestamptz, p_en_ver_at timestamptz,
  p_fi_flag boolean
) returns void language plpgsql as $pair$
declare fi_id bigint; en_id bigint;
begin
  insert into booking.site_texts(key, lang, class, kind, max_len, published_text, published_version, latest_version, status, needs_translation, published_at, created_at)
  values (p_key, 'fi', 'normal', 'plain', 400, p_fi, 1, 1, 'published', coalesce(p_fi_flag, false), p_fi_at, coalesce(p_fi_created, now()));
  insert into booking.site_texts(key, lang, class, kind, max_len, published_text, published_version, latest_version, status, needs_translation, published_at, created_at)
  values (p_key, 'en', 'normal', 'plain', 400, p_en, case when btrim(coalesce(p_en, '')) = '' then 0 else 1 end, case when btrim(coalesce(p_en, '')) = '' then 0 else 1 end,
          case when btrim(coalesce(p_en, '')) = '' then 'empty' else 'published' end, false, p_en_at, coalesce(p_en_created, now()));
  select id into fi_id from booking.site_texts where key = p_key and lang = 'fi';
  select id into en_id from booking.site_texts where key = p_key and lang = 'en';
  if btrim(coalesce(p_fi, '')) <> '' then
    insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
    values (fi_id, 1, p_fi, 'published', 0, 'system', 't237', 't237', coalesce(p_fi_ver_at, p_fi_at, p_fi_created), '{}', false);
  end if;
  if btrim(coalesce(p_en, '')) <> '' then
    insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
    values (en_id, 1, p_en, 'published', 0, 'system', 't237', 't237', coalesce(p_en_ver_at, p_en_at, p_en_created), '{}', false);
  end if;
end $pair$;

do $t$
declare
  sig_stale text := 'booking.svc_texts_stale_en(integer)';
  sig_en text := 'booking.svc_set_product_text_en(bigint,text,text,text)';
  src text;
  r jsonb;
  ids jsonb;
  v_id bigint;
  v_fi text;
  v_en text;
  v_price numeric;
  v_vat numeric;
  v_slug text;
  v_url text;
  v_active boolean;
  v_name text;
  v_name_en text;
  v_price_text text;
  log text;
  np int;
  nf int;
  stale boolean;
  u_ed uuid := gen_random_uuid();
  u_ap uuid := gen_random_uuid();
  v_at timestamptz;
begin
  select pg_get_functiondef(sig_stale::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path TO ''''%' and src like '%_text_effective_at%' and src not like '%updated_at%', 'A1 stale: definer, ei updated_at-vertailua');
  select pg_get_functiondef(sig_en::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path TO ''''%' and src like '%_text_publish%' and src like '%_text_touch_en_current%', 'A2 en-kirjoitus: julkaisu ja identtisen ajan päivitys');
  select pg_get_functiondef('booking._text_publish(bigint)'::regprocedure) into src;
  perform pg_temp.ck(src like '%lang = ''en''%' and src like '%needs_translation = false%' and src not like '%lang <> t.lang%', 'A3 julkaisu ei nosta vastakielen lippua molempiin suuntiin');
  perform pg_temp.ck(
    has_function_privilege('service_role', sig_stale, 'execute')
    and not has_function_privilege('anon', sig_stale, 'execute')
    and not has_function_privilege('authenticated', sig_stale, 'execute')
    and has_function_privilege('service_role', sig_en, 'execute')
    and not has_function_privilege('authenticated', sig_en, 'execute')
    and not has_function_privilege('anon', 'booking._text_effective_at(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._text_touch_en_current(bigint)', 'execute'),
    'A4 execute vain service_role');
  perform pg_temp.ck(
    exists (select 1 from booking.settings where key = 'booking_237_needs_translation_reset')
    and exists (select 1 from booking.settings where key = 'booking_237_en_timestamp_touch'),
    'A5 kertakorjauksen kirjaukset');

  -- Muut suomen rivit pois listalta, jotta testiavaimet mahtuvat 500:n rajaan. Transaktio peruuttaa.
  update booking.site_texts
     set class = 'locked'
   where lang = 'fi' and class <> 'locked'
     and key not like 't237.%'
     and key not like 'product.7.%';

  -- 1) NULL published_at + englanti olemassa, vertailuaika ei ole suomea uudempi -> ei vanha.
  -- updated_at nostetaan lippupäivityksellä, eikä se saa tehdä rivistä vanhaa.
  perform pg_temp.pair('t237.nullat', 'Suomi null', 'English null',
    null, now() - interval '1 day',
    now() - interval '10 days', now() - interval '10 days',
    now() - interval '10 days', now() - interval '1 day',
    true);
  update booking.site_texts set needs_translation = true where key = 't237.nullat' and lang = 'fi';
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  execute 'reset role';
  stale := exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'key' = 't237.nullat');
  perform pg_temp.ck(not stale, 'B1 FI published_at NULL ja EN olemassa ei ole vanha');

  -- Version julkaisuaika on suomea uudempi vaikka sarakkeen published_at on NULL -> vanha.
  perform pg_temp.pair('t237.verat', 'Suomi versio', 'English versio',
    null, now() - interval '2 days',
    now() - interval '10 days', now() - interval '10 days',
    clock_timestamp(), now() - interval '2 days',
    false);
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  execute 'reset role';
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(r -> 'items') e
     where e ->> 'key' = 't237.verat' and e ->> 'reason' = 'older'),
    'B2 FI versioaika EN:tä uudempi -> vanha');

  -- 2) Suomi muokattu englannin jälkeen -> vanha.
  perform pg_temp.pair('t237.after', 'Suomi uusi', 'English vanha',
    clock_timestamp(), clock_timestamp() - interval '2 hours',
    now() - interval '1 day', now() - interval '1 day',
    null, null, true);
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  execute 'reset role';
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(r -> 'items') e
     where e ->> 'key' = 't237.after' and e ->> 'reason' = 'older'),
    'C1 FI muokattu EN jälkeen -> vanha');

  -- Englannin julkaisu ei nosta suomen needs_translation-lippua. Suomen muutos nostaa englannin.
  perform pg_temp.pair('t237.dir', 'Suomi alku', 'English start',
    now() - interval '1 day', now() - interval '1 day',
    now() - interval '2 days', now() - interval '2 days',
    null, null, false);
  r := booking.texts_propose('t237.dir', 'fi', 'Suomi alku ja lisa', 't237');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'D1 suomen ehdotus: ' || coalesce(r::text, 'null'));
  r := booking.admin_texts_approve((r ->> 'version_id')::bigint, 't237', true);
  perform pg_temp.ck((r ->> 'status') = 'published', 'D2 suomen julkaisu');
  perform pg_temp.ck((select needs_translation from booking.site_texts where key = 't237.dir' and lang = 'en'), 'D3 suomen muutos merkitsee englannin needs_translation');
  perform pg_temp.ck(not (select needs_translation from booking.site_texts where key = 't237.dir' and lang = 'fi'), 'D4 suomen oma lippu jää falseksi');
  perform pg_temp.ck((select published_text from booking.site_texts where key = 't237.dir' and lang = 'en') = 'English start', 'D5 englannin teksti ei muuttunut suomen julkaisussa');
  update booking.site_texts set needs_translation = true where key = 't237.dir' and lang = 'fi';
  r := booking.texts_propose('t237.dir', 'en', 'English start plus', 't237');
  r := booking.admin_texts_approve((r ->> 'version_id')::bigint, 't237', true);
  perform pg_temp.ck(not (select needs_translation from booking.site_texts where key = 't237.dir' and lang = 'fi'), 'D6 EN-julkaisu nollaa suomen needs_translation');
  perform pg_temp.ck((select published_text from booking.site_texts where key = 't237.dir' and lang = 'fi') = 'Suomi alku ja lisa', 'D7 suomen teksti ei muuttunut EN-julkaisussa');

  -- 3) Identtinen englanti: ehdotus ja hyväksyntä päivittävät ajan, rivi poistuu listalta.
  perform pg_temp.pair('t237.same', 'Suomi sama', 'Already correct',
    clock_timestamp(), clock_timestamp() - interval '3 hours',
    now() - interval '1 day', now() - interval '1 day',
    null, null, true);
  select published_text into v_fi from booking.site_texts where key = 't237.same' and lang = 'fi';
  r := booking.texts_propose('t237.same', 'en', 'Already correct', 't237');
  perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'refreshed')::boolean and (r ->> 'unchanged')::boolean, 'E1 identtinen ehdotus päivittää ajan: ' || coalesce(r::text, 'null'));
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  execute 'reset role';
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'key' = 't237.same'), 'E2 identtinen englanti ei ole listalla');
  perform pg_temp.ck((select published_text from booking.site_texts where key = 't237.same' and lang = 'fi') = v_fi, 'E3 suomen teksti ennallaan');
  perform pg_temp.ck((select published_text from booking.site_texts where key = 't237.same' and lang = 'en') = 'Already correct', 'E4 englannin teksti ennallaan');
  perform pg_temp.ck(not (select needs_translation from booking.site_texts where key = 't237.same' and lang = 'fi'), 'E5 suomen lippu false identtisen jälkeen');
  perform pg_temp.ck(pg_temp.err($q$select booking.texts_propose('t237.same', 'en', 'Already correct', 't237')$q$) = 'no_change', 'E6 jo ajan tasalla oleva identtinen on no_change');

  perform pg_temp.pair('t237.appr', 'Suomi hyväksy', 'Approve same',
    clock_timestamp(), clock_timestamp() - interval '4 hours',
    now() - interval '1 day', now() - interval '1 day',
    null, null, true);
  select id into v_id from booking.site_texts where key = 't237.appr' and lang = 'en';
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, escalation, protected)
  values (v_id, 2, 'Approve same', 'proposed', 1, 'bot', 't237', 't237', '{}', false)
  returning id into v_id;
  r := booking.admin_texts_approve(v_id, 't237 sama', true);
  perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'refreshed')::boolean, 'E7 identtisen hyväksyntä: ' || coalesce(r::text, 'null'));
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  execute 'reset role';
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'key' = 't237.appr'), 'E8 hyväksytty identtinen englanti ei ole listalla');
  perform pg_temp.ck((select published_text from booking.site_texts where key = 't237.appr' and lang = 'fi') = 'Suomi hyväksy', 'E9 suomi ennallaan hyväksynnässä');
  perform pg_temp.ck(not (select needs_translation from booking.site_texts where key = 't237.appr' and lang = 'fi'), 'E10 suomen lippu false hyväksynnän jälkeen');

  -- Kertakorjaus: ajan tasalla oleva lippu nollataan, vanhempi ja tyhjä englanti eivät.
  perform pg_temp.pair('t237.fixcur', 'Suomi lippu', 'English current',
    now() - interval '2 days', now() - interval '1 day',
    now() - interval '3 days', now() - interval '3 days',
    null, null, true);
  perform pg_temp.pair('t237.fixold', 'Suomi vanha lippu', 'English older',
    clock_timestamp(), clock_timestamp() - interval '5 hours',
    now() - interval '1 day', now() - interval '1 day',
    null, null, true);
  perform pg_temp.pair('t237.fixempty', 'Suomi tyhja en', '',
    now() - interval '1 day', null,
    now() - interval '2 days', now() - interval '2 days',
    null, null, true);
  select published_text into v_fi from booking.site_texts where key = 't237.fixcur' and lang = 'fi';
  select published_text into v_en from booking.site_texts where key = 't237.fixcur' and lang = 'en';
  ids := booking._text_clear_fi_flags_when_en_current();
  perform pg_temp.ck(not (select needs_translation from booking.site_texts where key = 't237.fixcur' and lang = 'fi'), 'F1 ajan tasalla olevan suomen lippu nollattiin');
  perform pg_temp.ck((select needs_translation from booking.site_texts where key = 't237.fixold' and lang = 'fi'), 'F2 vanhemman englannin suomen lippu jää');
  perform pg_temp.ck((select needs_translation from booking.site_texts where key = 't237.fixempty' and lang = 'fi'), 'F3 tyhjä englanti ei nollaa lippua');
  perform pg_temp.ck((select published_text from booking.site_texts where key = 't237.fixcur' and lang = 'fi') = v_fi
    and (select published_text from booking.site_texts where key = 't237.fixcur' and lang = 'en') = v_en, 'F4 lippukorjaus ei muuta tekstiä');
  perform pg_temp.ck(ids @> jsonb_build_array((select id from booking.site_texts where key = 't237.fixcur' and lang = 'fi')), 'F5 funktio palauttaa korjatun id:n');

  -- Tuotekenttä: uusi englanti ei nosta suomen lippua; identtinen poistuu listalta; hinta ja suomi ennallaan.
  select price, vat_rate, slug, booking_url, active, name, name_en, price_text
    into v_price, v_vat, v_slug, v_url, v_active, v_name, v_name_en, v_price_text
    from kb.products where id = 7;
  perform pg_temp.ck(v_name is not null, 'G0 tuote 7 löytyy');
  if v_name is not null then
    update booking.site_texts set needs_translation = true where key = 'product.7.name' and lang = 'fi';
    execute 'set local role service_role';
    r := booking.svc_set_product_text_en(7, 'name', 'Heritage sauna session', 'kaantaja-bot');
    execute 'reset role';
    perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'text' = 'Heritage sauna session', 'G1 en-nimi päivittyi: ' || coalesce(r::text, 'null'));
    perform pg_temp.ck(not (select needs_translation from booking.site_texts where key = 'product.7.name' and lang = 'fi'), 'G2 EN-kirjoitus ei jätä suomen lippua päälle');
    perform pg_temp.ck((select name from kb.products where id = 7) = v_name, 'G3 suomen nimi ennallaan');
    perform pg_temp.ck((select name_en from kb.products where id = 7) = 'Heritage sauna session', 'G4 name_en lähdetaulussa');
    perform pg_temp.ck((select price from kb.products where id = 7) is not distinct from v_price
      and (select vat_rate from kb.products where id = 7) is not distinct from v_vat
      and (select slug from kb.products where id = 7) is not distinct from v_slug
      and (select booking_url from kb.products where id = 7) is not distinct from v_url
      and (select active from kb.products where id = 7) is not distinct from v_active
      and (select price_text from kb.products where id = 7) is not distinct from v_price_text, 'G5 hinta, ALV, slug, URL ja active ennallaan');
    update booking.site_texts set published_at = clock_timestamp(), needs_translation = true
     where key = 'product.7.name' and lang = 'fi';
    execute 'set local role service_role';
    r := booking.svc_texts_stale_en(500);
    perform pg_temp.ck(exists (
      select 1 from jsonb_array_elements(r -> 'items') e
       where e ->> 'key' = 'product.7.name' and e ->> 'reason' = 'older'), 'G6 myöhempi suomi palauttaa listalle');
    r := booking.svc_set_product_text_en(7, 'name', 'Heritage sauna session', 'kaantaja-bot');
    execute 'reset role';
    perform pg_temp.ck((r ->> 'refreshed')::boolean, 'G7 identtinen tuotekenttä päivittää ajan: ' || coalesce(r::text, 'null'));
    execute 'set local role service_role';
    r := booking.svc_texts_stale_en(500);
    execute 'reset role';
    perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'key' = 'product.7.name'), 'G8 identtinen tuote ei ole listalla');
    perform pg_temp.ck((select name from kb.products where id = 7) = v_name, 'G9 identtinen kirjoitus ei muuta suomea');
    perform pg_temp.ck((select name_en from kb.products where id = 7) = 'Heritage sauna session', 'G10 identtinen kirjoitus ei vaihda englantia');
    perform pg_temp.ck((select price from kb.products where id = 7) is not distinct from v_price
      and (select vat_rate from kb.products where id = 7) is not distinct from v_vat, 'G11 hinta ja ALV yhä ennallaan');
    perform pg_temp.ck(not (select needs_translation from booking.site_texts where key = 'product.7.name' and lang = 'fi'), 'G12 identtinen tuote nollaa suomen lipun');
  end if;

  -- Oikeudet: ajan päivitys kuittaa englannin ajan tasalla olevaksi, joten se vaatii hyväksyntäoikeuden.
  insert into auth.users(id, email) values (u_ed, 't237-ed@example.test'), (u_ap, 't237-ap@example.test');
  insert into booking.text_bots(user_id, label, role_code) values (u_ed, 't237 ehdottaja', 'text_editor'), (u_ap, 't237 hyväksyjä', 'text_editor_approver');
  perform pg_temp.pair('t237.perm', 'Suomi oikeus', 'Same perm',
    clock_timestamp(), clock_timestamp() - interval '3 hours',
    now() - interval '1 day', now() - interval '1 day',
    null, null, true);
  select published_at into v_at from booking.site_texts where key = 't237.perm' and lang = 'en';
  perform test.login(u_ed);
  v_fi := pg_temp.err($q$select booking.texts_propose('t237.perm', 'en', 'Same perm', 't237')$q$);
  perform test.logout();
  perform pg_temp.ck(v_fi = 'no_change', 'H1 pelkkä texts.propose ei kuittaa vanhaa englantia: ' || coalesce(v_fi, 'null'));
  perform pg_temp.ck((select published_at from booking.site_texts where key = 't237.perm' and lang = 'en') is not distinct from v_at
    and (select needs_translation from booking.site_texts where key = 't237.perm' and lang = 'fi'), 'H2 aika ja suomen lippu ennallaan');
  perform test.login(u_ap);
  r := booking.texts_propose('t237.perm', 'en', 'Same perm', 't237');
  perform test.logout();
  perform pg_temp.ck((r ->> 'refreshed')::boolean and not (r ->> 'protected')::boolean, 'H3 texts.approve kuittaa tavallisen: ' || coalesce(r::text, 'null'));

  perform pg_temp.pair('t237.prot', 'Suomi suojattu', 'Same protected',
    clock_timestamp(), clock_timestamp() - interval '3 hours',
    now() - interval '1 day', now() - interval '1 day',
    null, null, true);
  update booking.site_texts set class = 'protected' where key = 't237.prot';
  select published_at into v_at from booking.site_texts where key = 't237.prot' and lang = 'en';
  perform test.login(u_ap);
  v_fi := pg_temp.err($q$select booking.texts_propose('t237.prot', 'en', 'Same protected', 't237')$q$);
  perform test.logout();
  perform pg_temp.ck(v_fi = 'no_change', 'H4 suojattua ei kuitata ilman approve_protected (propose): ' || coalesce(v_fi, 'null'));
  select id into v_id from booking.site_texts where key = 't237.prot' and lang = 'en';
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, escalation, protected)
  values (v_id, 2, 'Same protected', 'proposed', 1, 'bot', 't237', 't237', '{}', true)
  returning id into v_id;
  perform test.login(u_ap);
  v_fi := pg_temp.err(format('select booking.admin_texts_approve(%s, %L, true)', v_id, 't237'));
  perform test.logout();
  perform pg_temp.ck(v_fi = 'forbidden', 'H5 suojattua ei kuitata ilman approve_protected (approve): ' || coalesce(v_fi, 'null'));
  perform pg_temp.ck((select published_at from booking.site_texts where key = 't237.prot' and lang = 'en') is not distinct from v_at
    and (select status from booking.site_text_versions where id = v_id) = 'proposed', 'H6 suojatun aika ja versio ennallaan');
  r := booking.admin_texts_approve(v_id, 't237', true);
  perform pg_temp.ck((r ->> 'refreshed')::boolean and (r ->> 'protected')::boolean, 'H7 approve_protected kuittaa suojatun: ' || coalesce(r::text, 'null'));

  log := current_setting('t237.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
