-- booking_302_cancellation_tier_classification: tuotteiden peruutusehtoryhmä (booking.product_config.cancellation_tier, booking_284).
-- Joonaksen yötyöpyyntö 13.11.2026 (t1731u), lupa ajaa tuotantoon ilman etukäteistarkistusta. Ei lippumuutoksia, ei koodimuutoksia.
-- Lähde: julkaistut ehdot (kb.policies 3 = saunotus.fi/ehdot "Peruutukset ja muutokset", FAQ 10):
--   general (48 h)        = yleiset vuorot; hoidot/saunotukset/rituaalit (Joonas 29.10.: ei erillisiä ehtoja, 24.10.: ei asiakkaan omaa hyvitystä alle 48 h)
--   private_event (14 vrk) = yksityisvuorot (myös yritysten), tapahtumat, perinnesaunotusillat, seremoniat/yksityistilaisuudet
--   null (jätetään)        = koulutukset/kurssit (omat ehdot kb.policies 6: 30 vrk, 60 € toimistokulu, varausmaksu), lahjakortit, vuosikortti,
--                            vuokratuotteet/myyntituotteet, tarjouspyyntötuote 50 -> asiakas ohjataan henkilökunnalle
-- Kohdistus slugilla (DEV- ja PROD-id:t eroavat: joulusauna DEV 110 / PROD 113). Rollback: ../302/ROLLBACK_<env>.sql
set local lock_timeout = '5s';
select set_config('booking.text_apply', 'on', true);  -- ei sivutekstisynkkaa (sarake ei ole tekstilähde)
do $pre$
declare v_missing text;
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'product_config' and column_name = 'cancellation_tier') then
    raise exception 'booking_302: booking_284 (cancellation_tier) puuttuu. Ei muutoksia.';
  end if;
  select string_agg(m.slug, ', ') into v_missing
    from (values
  ('yleinensauna','general'),
  ('miestensauna-2','general'),
  ('naistensauna','general'),
  ('hiljainen-sauna','general'),
  ('turvetorstai','general'),
  ('tunnin-vuoro','general'),
  ('saunarituaali-ja-savusaunavuoro','general'),
  ('saunotusrituaali','general'),
  ('saunahoito-2','general'),
  ('saunotus-2','general'),
  ('syvasaunotus','general'),
  ('vihtahoito-opiskelijatyona','general'),
  ('perinnevihdonta','general'),
  ('perinnevihdonta-kahdelle','general'),
  ('vihtahoito','general'),
  ('vihtahoito-kahdelle','general'),
  ('turvehoito-15min','general'),
  ('turvehoito-30','general'),
  ('turvehoito-koko-vartalo','general'),
  ('saunahieronta-60min','general'),
  ('saunahieronta-30','general'),
  ('perinnesaunotus-yhdelle','general'),
  ('perinnesaunotusilta','private_event'),
  ('perinnesaunotus-ryhmalle','private_event'),
  ('oma-saunavuoro','private_event'),
  ('jalkiloylyt','private_event'),
  ('perinnesaunotus-jalkiloylyille','private_event'),
  ('perinnesaunotus-yksityisvuorolle','private_event'),
  ('morsiussauna','private_event'),
  ('synttarisauna','private_event'),
  ('turvesauna','private_event'),
  ('naisten-joulusauna','private_event'),
  ('sipoonjoen-kekri','private_event'),
  ('saunottajien-yhteisopaiva-2','private_event'),
  ('saunavuoro-yrityksille','private_event'),
  ('jalkiloylyt-yrityksille','private_event'),
  ('sipoonjoen-joulusauna','private_event')) m(slug, tier)
   where (select count(*) from kb.products p join booking.product_config pc on pc.product_id = p.id where p.slug = m.slug) <> 1;
  if v_missing is not null then raise exception 'booking_302: slug puuttuu tai ei yksiselitteinen: %. Ei muutoksia.', v_missing; end if;
end $pre$;

update booking.product_config pc set cancellation_tier = m.tier
  from kb.products p,
       (values
  ('yleinensauna','general'),
  ('miestensauna-2','general'),
  ('naistensauna','general'),
  ('hiljainen-sauna','general'),
  ('turvetorstai','general'),
  ('tunnin-vuoro','general'),
  ('saunarituaali-ja-savusaunavuoro','general'),
  ('saunotusrituaali','general'),
  ('saunahoito-2','general'),
  ('saunotus-2','general'),
  ('syvasaunotus','general'),
  ('vihtahoito-opiskelijatyona','general'),
  ('perinnevihdonta','general'),
  ('perinnevihdonta-kahdelle','general'),
  ('vihtahoito','general'),
  ('vihtahoito-kahdelle','general'),
  ('turvehoito-15min','general'),
  ('turvehoito-30','general'),
  ('turvehoito-koko-vartalo','general'),
  ('saunahieronta-60min','general'),
  ('saunahieronta-30','general'),
  ('perinnesaunotus-yhdelle','general'),
  ('perinnesaunotusilta','private_event'),
  ('perinnesaunotus-ryhmalle','private_event'),
  ('oma-saunavuoro','private_event'),
  ('jalkiloylyt','private_event'),
  ('perinnesaunotus-jalkiloylyille','private_event'),
  ('perinnesaunotus-yksityisvuorolle','private_event'),
  ('morsiussauna','private_event'),
  ('synttarisauna','private_event'),
  ('turvesauna','private_event'),
  ('naisten-joulusauna','private_event'),
  ('sipoonjoen-kekri','private_event'),
  ('saunottajien-yhteisopaiva-2','private_event'),
  ('saunavuoro-yrityksille','private_event'),
  ('jalkiloylyt-yrityksille','private_event'),
  ('sipoonjoen-joulusauna','private_event')) m(slug, tier)
 where p.id = pc.product_id and p.slug = m.slug and pc.cancellation_tier is distinct from m.tier;

do $post$
declare v int;
begin
  select count(*) into v from booking.product_config where cancellation_tier is not null;
  if v <> 37 then raise exception 'booking_302: odotettiin 37 luokiteltua, saatiin %', v; end if;
end $post$;
