-- ROLLBACK booking_170_osoite_saunotus_fi: palauttaa kb.productsin 11 kenttään vanhan kehitysosoitteen täsmälleen.
-- Ajetaan vain, jos booking_170 halutaan perua. Koodi (LEGACY_CANONICAL) ohjaa vanhan osoitteen silloinkin sivuston omaan polkuun.
-- Vartija: jokaisen kentän md5 on oltava migraation kirjoittama (tai jo alkuperäinen → ohitetaan), muuten exception ennen yhtään muutosta.
-- needs_translation: kuten migraatiossa, product.<id>.description [fi/en] -rivien liput otetaan talteen ennen palautusta ja palautetaan
-- täsmälleen sen jälkeen (trigger zz_site_text_sync muuttaisi ne). Koska migraatio ei muuttanut lippuja, tila on ajon jälkeen sama kuin
-- ennen booking_170:tä. Vartija: rivin julkaistu teksti on oltava täsmälleen palautettu alkuperäinen (md5 = from_md5), muuten exception.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $rfi$
declare
  old_base constant text := 'https://uusi.saunotus.com';
  new_base constant text := 'https://saunotus.fi';
  r record; t record; cur text; cnt int; n int := 0; skip int := 0;
  todo jsonb := '{}';         -- palautettavat kentät: '<tuote>:<sarake>' → from_md5
  pids int[] := '{}';
  nt_before jsonb := '{}';    -- site_texts.id → needs_translation ennen palautusta
  nt_n int := 0;
begin
  for r in select * from (values
    (1, 'description', 1, '75312781e1c3861c69c0112428ebf5f1', 'f0561a9145ea81e3854f1123fa714f0e'),
    (1, 'description_en', 1, '6a13d49ee1062e4daa24e06eb7e3d5ab', 'd54cfa6c0285dff0ef8e0798d641a971'),
    (7, 'description', 1, 'f2dde2a51904c4cdef62b32a0a9f2416', '902eab3acb73ea0cd05fc2b52721d86e'),
    (7, 'description_en', 1, '3a71fb4a777706c5aa35971402163309', 'c2ff0e24d34dd0a92c591f3fa06072e4'),
    (25, 'description', 1, 'f800f8b84a5ff1a2644c33c8b5a5dbdd', '997d7234a1018e3e6cbddcf2b9c2e0a9'),
    (25, 'description_en', 1, 'daf48be5d93eb6c82061309e757bb329', '6815e2c9830f476b691b719905c507dc'),
    (26, 'description', 1, '7a97893d31f62f1fe0fcc0970ac4f256', 'd66c8a9d9764ae632f71e6a1c3193500'),
    (26, 'description_en', 1, 'db2bef46783a45b5a3540509dca42c51', '55c23bdd08657f938654a921ec467685'),
    (38, 'description', 11, '311d6c639941a129d4c19c50cd6c0653', '9daeb541dd2d9979e2253fcdc876c6b7'),
    (38, 'description_en', 11, '515737aa1a9c3c7b8130da0a7e97132f', '9ff3964455b08b596172e47ab42c0f91'),
    (50, 'source_url', 1, '2161d42f25636101c92bdb11b8891b00', '75d6af77b63c3b473172ea2c99da3073')
  ) v(product_id, col, occurrences, from_md5, to_md5) loop
    if r.col not in ('description', 'description_en', 'source_url') then raise exception 'rollback booking_170: sarake % ei sallittu', r.col; end if;
    execute format('select %I from kb.products where id = $1', r.col) into cur using r.product_id;
    if md5(cur) = r.from_md5 then skip := skip + 1; continue; end if;
    if cur is null or md5(cur) <> r.to_md5 then
      raise exception 'rollback booking_170: tuote % % on muuttunut migraation jälkeen (md5 %) – ei muutoksia', r.product_id, r.col, md5(cur);
    end if;
    cnt := (length(cur) - length(replace(cur, new_base, ''))) / length(new_base);
    if cnt <> r.occurrences or md5(replace(cur, new_base, old_base)) <> r.from_md5 then
      raise exception 'rollback booking_170: tuote % %: palautus ei tuottaisi alkuperäistä tekstiä', r.product_id, r.col;
    end if;
    todo := todo || jsonb_build_object(r.product_id || ':' || r.col, r.from_md5);
    if not r.product_id = any(pids) then pids := pids || r.product_id; end if;
  end loop;

  select coalesce(jsonb_object_agg(x.id::text, x.needs_translation), '{}') into nt_before
    from (select st.id, st.needs_translation from booking.site_texts st
           where st.source_table = 'kb.products' and st.source_pk = any(select p::text from unnest(pids) p)
             and st.key = 'product.' || st.source_pk || '.description' and st.lang in ('fi', 'en')
           for update) x;

  for r in select * from (values
    (1, 'description', 1, '75312781e1c3861c69c0112428ebf5f1', 'f0561a9145ea81e3854f1123fa714f0e'),
    (1, 'description_en', 1, '6a13d49ee1062e4daa24e06eb7e3d5ab', 'd54cfa6c0285dff0ef8e0798d641a971'),
    (7, 'description', 1, 'f2dde2a51904c4cdef62b32a0a9f2416', '902eab3acb73ea0cd05fc2b52721d86e'),
    (7, 'description_en', 1, '3a71fb4a777706c5aa35971402163309', 'c2ff0e24d34dd0a92c591f3fa06072e4'),
    (25, 'description', 1, 'f800f8b84a5ff1a2644c33c8b5a5dbdd', '997d7234a1018e3e6cbddcf2b9c2e0a9'),
    (25, 'description_en', 1, 'daf48be5d93eb6c82061309e757bb329', '6815e2c9830f476b691b719905c507dc'),
    (26, 'description', 1, '7a97893d31f62f1fe0fcc0970ac4f256', 'd66c8a9d9764ae632f71e6a1c3193500'),
    (26, 'description_en', 1, 'db2bef46783a45b5a3540509dca42c51', '55c23bdd08657f938654a921ec467685'),
    (38, 'description', 11, '311d6c639941a129d4c19c50cd6c0653', '9daeb541dd2d9979e2253fcdc876c6b7'),
    (38, 'description_en', 11, '515737aa1a9c3c7b8130da0a7e97132f', '9ff3964455b08b596172e47ab42c0f91'),
    (50, 'source_url', 1, '2161d42f25636101c92bdb11b8891b00', '75d6af77b63c3b473172ea2c99da3073')
  ) v(product_id, col, occurrences, from_md5, to_md5) loop
    execute format('update kb.products set %1$I = replace(%1$I, $1, $2) where id = $3 and md5(%1$I) = $4', r.col)
      using new_base, old_base, r.product_id, r.to_md5;
    get diagnostics cnt = row_count;
    n := n + cnt;
  end loop;

  for t in select st.id, st.key, st.lang, st.source_pk, st.source_column, st.needs_translation, st.published_text
             from booking.site_texts st where st.id::text in (select jsonb_object_keys(nt_before)) order by st.id loop
    continue when t.needs_translation = (nt_before ->> t.id::text)::boolean;
    if todo ->> (t.source_pk || ':' || t.source_column) is null and not exists (
         select 1 from booking.site_texts o where o.key = t.key and o.lang in ('fi', 'en') and o.lang <> t.lang
            and todo ->> (o.source_pk || ':' || o.source_column) is not null) then
      raise exception 'rollback booking_170: % [%] needs_translation muuttui, mutta kumpaakaan kieliversiota ei palautettu – ei muutoksia', t.key, t.lang;
    end if;
    if md5(t.published_text) is distinct from (select md5(coalesce(to_jsonb(p) ->> t.source_column, '')) from kb.products p where p.id::text = t.source_pk)
       or (todo ->> (t.source_pk || ':' || t.source_column) is not null and md5(t.published_text) <> todo ->> (t.source_pk || ':' || t.source_column)) then
      raise exception 'rollback booking_170: % [%] julkaistu teksti ei ole palautettu alkuperäinen (md5 %) – ei muutoksia', t.key, t.lang, md5(t.published_text);
    end if;
    update booking.site_texts set needs_translation = (nt_before ->> t.id::text)::boolean where id = t.id;
    nt_n := nt_n + 1;
  end loop;
  raise notice 'rollback booking_170: palautettu % kenttää, ohitettu %; needs_translation palautettu ennalleen % rivillä', n, skip, nt_n;
end
$rfi$;
