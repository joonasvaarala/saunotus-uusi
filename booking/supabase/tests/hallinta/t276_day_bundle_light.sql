-- t276: booking_276 – admin_ui_texts, kevyempi admin_day_bundle ja admin_day_data.
-- Ajetaan migraatioiden, fixtures/10_test_helpers.sql:n ja booking_276:n JÄLKEEN paikallisessa PG17:ssä.
-- Tulos: TESTRESULT pass=N fail=M (raise exception → koko testi kumoutuu). Ei koske tuotantoa.
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t276_r(ok boolean, label text) on commit drop;
grant all on t276_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t276_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql; return 'NO ERROR'; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
do $t$
declare
  v_mgr uuid := test.mk_staff('mgr276@example.test', 'manager');
  v_staff uuid := test.mk_staff('staff276@example.test', 'staff');
  v_user uuid := test.mk_user('asiakas276@example.test');
  v_day date := (now() at time zone 'Europe/Helsinki')::date;
  pub jsonb; adm jsonb; b jsonb; d jsonb; n_pub_admin int; n_adm int; n_bad int; n_adm_fi int;
begin
  -- Testirivit: yksi hallinnan ja yksi julkinen avain (molemmat julkaistu), yksi lukittu hallinnan avain.
  insert into booking.site_texts(key, lang, published_text, published_version, class)
  values ('ui.admin.t276.title', 'fi', 'Hallinta T276', 1, 'normal'), ('ui.admin.t276.title', 'en', 'Admin T276', 1, 'normal'),
         ('ui.shop.t276.title', 'fi', 'Kauppa T276', 1, 'normal'), ('ui.admin.t276.locked', 'fi', 'Lukittu', 1, 'locked')
  on conflict do nothing;

  perform test.logout();
  pub := booking.public_get_site_texts(null);
  select count(*) into n_pub_admin from jsonb_array_elements(pub->'texts') e
   where e->>'key' like 'ui.admin.%' or e->>'key' like 'ui.pos.%' or e->>'key' like 'ui.upsell.%' or e->>'key' like 'admin.%';

  -- Oikeudet: anon ja kirjautunut ei-henkilökunta eivät saa kutsua uusia funktioita.
  perform test.anon();
  perform pg_temp.ck(pg_temp.err('select booking.admin_ui_texts(null)') like '42501%', 'A1: anon ei saa admin_ui_texts (execute revoked)');
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_day_data(%L)', v_day)) like '42501%', 'A2: anon ei saa admin_day_data');
  perform test.logout();
  perform test.login(v_user);
  perform pg_temp.ck(pg_temp.err('select booking.admin_ui_texts(null)') <> 'NO ERROR', 'A3: ei-henkilökunta ei saa admin_ui_texts');
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_day_data(%L)', v_day)) <> 'NO ERROR', 'A4: ei-henkilökunta ei saa admin_day_data');
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_day_bundle(%L)', v_day)) <> 'NO ERROR', 'A5: ei-henkilökunta ei saa admin_day_bundle');
  perform test.logout();

  -- Tekstit: sama muoto, vain hallinnan avaimet, kaikki hallinnan avaimet mukana, lukittu ei mukana.
  perform test.login(v_staff);
  adm := booking.admin_ui_texts(null);
  perform pg_temp.ck(adm->>'ok' = 'true' and jsonb_typeof(adm->'texts') = 'array', 'T1: { ok: true, texts: [...] }');
  select count(*) into n_adm from jsonb_array_elements(adm->'texts');
  select count(*) into n_bad from jsonb_array_elements(adm->'texts') e
   where not (e->>'key' like 'ui.admin.%' or e->>'key' like 'ui.pos.%' or e->>'key' like 'ui.upsell.%' or e->>'key' like 'admin.%');
  perform pg_temp.ck(n_bad = 0, 'T2: ei julkisia avaimia (' || n_bad || ')');
  perform pg_temp.ck(n_adm = n_pub_admin, format('T3: hallinnan avaimet = public_get_site_texts:n hallinta-avaimet (%s / %s)', n_adm, n_pub_admin));
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(adm->'texts') e where e->>'key' = 'ui.admin.t276.title' and e->>'lang' = 'en' and e->>'text' = 'Admin T276'
                                                                            and e ? 'version' and e ? 'placeholders'), 'T4: rivin kentät key/lang/text/version/placeholders');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(adm->'texts') e where e->>'key' in ('ui.shop.t276.title', 'ui.admin.t276.locked')), 'T5: julkinen ja lukittu pois');
  select count(*) into n_adm_fi from jsonb_array_elements(booking.admin_ui_texts('FI ')->'texts') e;
  perform pg_temp.ck(n_adm_fi > 0 and n_adm_fi < n_adm and not exists (select 1 from jsonb_array_elements(booking.admin_ui_texts('fi')->'texts') e where e->>'lang' <> 'fi'), 'T6: p_lang rajaa kielen');

  -- Päivänippu: sama avainjoukko kuin ennen, site_texts = admin_ui_texts.
  b := booking.admin_day_bundle(v_day);
  perform pg_temp.ck((select array_agg(k order by k) from jsonb_object_keys(b) k) =
    array['addons','date','extras','notes_bundle','options','payment_methods','permissions','products','reservations','resources','role','shifts','site_texts','view'], 'B1: admin_day_bundle-kentät ennallaan');
  perform pg_temp.ck(b->'site_texts'->'texts' = adm->'texts' and b->'site_texts'->>'ok' = 'true', 'B2: site_texts = admin_ui_texts(null)');
  perform pg_temp.ck(b->>'role' = 'staff', 'B3: rooli staff');

  -- Kevyt päivänvaihto: osajoukko nipusta, samat arvot.
  d := booking.admin_day_data(v_day);
  perform pg_temp.ck((select array_agg(k order by k) from jsonb_object_keys(d) k) =
    array['addons','date','extras','light','notes_bundle','options','reservations','shifts','view'], 'D1: admin_day_data-kentät');
  perform pg_temp.ck(d->'view' = b->'view' and d->'reservations' = b->'reservations' and d->'shifts' = b->'shifts' and d->'addons' = b->'addons'
                     and d->'options' = b->'options' and d->'extras' = b->'extras' and d->'notes_bundle' = b->'notes_bundle' and d->>'date' = b->>'date', 'D2: samat arvot kuin nipussa');
  perform pg_temp.ck(d->>'light' = 'true', 'D3: light = true');
  perform pg_temp.ck(pg_temp.err('select booking.admin_day_data(null)') like '%Päivä puuttuu%', 'D4: null-päivä → invalid_date');
  perform pg_temp.ck(length(d::text) < length(b::text), 'D5: kevyt nippu on pienempi');
  perform test.logout();

  perform test.login(v_mgr);
  perform pg_temp.ck(booking.admin_day_data(v_day + 1)->>'date' = (v_day + 1)::text, 'M1: manager saa admin_day_data');
  perform test.logout();

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t276_r where ok), (select count(*) from t276_r where not ok),
    coalesce((select string_agg(label, ' | ') from t276_r where not ok), 'ALL OK');
end $t$;
