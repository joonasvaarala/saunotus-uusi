-- booking_102: julkinen lähetys luo rivin ja jonoon ilmoituksen, jonka payloadissa on kaikki lomakkeen kentät.
-- Claim palauttaa saman quote-lohkon ja reply_to-osoitteen. Asiakkaan kuittauksen payload pysyy ohuena.
-- Ajo: psql -v ON_ERROR_STOP=1 -f booking/supabase/tests/companies/t102_business_quote_notify.sql
set local lock_timeout = '3s'; set local statement_timeout = '60s';
select set_config('t102.log', '', true);
create function public.t102_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t102.log', coalesce(current_setting('t102.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
grant execute on function public.t102_ck(boolean, text) to public;
do $t$
declare
  r jsonb; p jsonb; cl jsonb; rowj jsonb; qid bigint; nid bigint; log text; npass int; nfail int;
  v_email text; v_name text;
begin
  v_email := booking._setting('business_quote_notify_email') #>> '{}';
  v_name := booking._setting('business_quote_notify_name') #>> '{}';
  perform public.t102_ck(v_email = 'savusauna@saunotus.fi', 'S1 ilmoitusosoite savusauna@saunotus.fi, oli ' || coalesce(v_email, 'null'));
  perform public.t102_ck(v_name = 'Joonas', 'S2 nimi Joonas, oli ' || coalesce(v_name, 'null'));

  update booking.settings set value = '""'::jsonb where key = 'business_quote_notify_email';
  update booking.settings set value = to_jsonb('savusauna@saunotus.fi'::text)
   where key = 'business_quote_notify_email' and nullif(btrim(coalesce(value #>> '{}', '')), '') is null;
  perform public.t102_ck(booking._setting('business_quote_notify_email') #>> '{}' = 'savusauna@saunotus.fi', 'S3 tyhjä osoite täyttyy');
  update booking.settings set value = to_jsonb('muu@example.test'::text) where key = 'business_quote_notify_email';
  update booking.settings set value = to_jsonb('savusauna@saunotus.fi'::text)
   where key = 'business_quote_notify_email' and nullif(btrim(coalesce(value #>> '{}', '')), '') is null;
  perform public.t102_ck(booking._setting('business_quote_notify_email') #>> '{}' = 'muu@example.test', 'S4 ei-tyhjää osoitetta ei ylikirjoiteta');
  update booking.settings set value = '""'::jsonb where key = 'business_quote_notify_name';
  update booking.settings set value = to_jsonb('Joonas'::text)
   where key = 'business_quote_notify_name' and nullif(btrim(coalesce(value #>> '{}', '')), '') is null;
  perform public.t102_ck(booking._setting('business_quote_notify_name') #>> '{}' = 'Joonas', 'S5 tyhjä nimi täyttyy Joonakseksi');
  update booking.settings set value = to_jsonb('savusauna@saunotus.fi'::text) where key = 'business_quote_notify_email';
  update booking.settings set value = to_jsonb('Joonas'::text) where key = 'business_quote_notify_name';

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.102"}', true);
  execute 'set local role anon';
  r := booking.public_create_business_quote(
    'Sipoon Testi Oy', 'Maija Meikäläinen', 'Maija@Example.Test', '040 123 4567',
    'ensi viikon perjantai', 12,
    '["vihta_workshop","ritual","other","sauna","forest_yoga","campfire_meal"]'::jsonb,
    'yrityssaunaretki', 'toive metsäkävelystä', 'en', true, '');
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform public.t102_ck(r = '{"ok":true,"code":"ok"}'::jsonb, 'R1 julkinen lähetys: ' || coalesce(r::text, 'null'));
  select id into qid from booking.business_quote_requests where email = 'maija@example.test';
  perform public.t102_ck(qid is not null and (select status from booking.business_quote_requests where id = qid) = 'new', 'R2 tauluun yksi rivi, tila new');
  perform public.t102_ck((select offerings from booking.business_quote_requests where id = qid) = array['ritual','forest_yoga','campfire_meal','sauna','vihta_workshop','other']::text[], 'R3 palvelut tallessa');

  select id, payload into nid, p from booking.email_outbox where kind = 'business_quote_notify' and dedupe_key = 'business_quote_notify:' || qid;
  perform public.t102_ck(nid is not null and (select locale from booking.email_outbox where id = nid) = 'fi', 'R4 ilmoitus jonossa, kieli fi');
  perform public.t102_ck(p ->> 'to_email' = 'savusauna@saunotus.fi' and p ->> 'to_name' = 'Joonas' and p ->> 'reply_to' = 'maija@example.test' and (p ->> 'quote_id')::bigint = qid, 'R5 vastaanottaja, reply-to ja tunnus');
  perform public.t102_ck(p ->> 'company_name' = 'Sipoon Testi Oy' and p ->> 'contact_name' = 'Maija Meikäläinen' and p ->> 'email' = 'maija@example.test' and p ->> 'phone' = '040 123 4567', 'R6 yritys, yhteyshenkilö, sähköposti, puhelin');
  perform public.t102_ck((p ->> 'persons')::int = 12 and p -> 'offerings' = '["ritual","forest_yoga","campfire_meal","sauna","vihta_workshop","other"]'::jsonb and p ->> 'offering_other' = 'yrityssaunaretki', 'R7 henkilömäärä ja palvelut');
  perform public.t102_ck(p ->> 'preferred_when' = 'ensi viikon perjantai' and p ->> 'message' = 'toive metsäkävelystä' and p ->> 'locale' = 'en' and (p ->> 'created_at')::timestamptz = (select created_at from booking.business_quote_requests where id = qid), 'R8 ajankohta, viesti, lomakkeen kieli, lähetysaika');
  perform public.t102_ck((select (payload - 'to_email' - 'to_name' - 'quote_id') = '{}'::jsonb and locale = 'en' from booking.email_outbox where kind = 'business_quote_ack' and dedupe_key = 'business_quote_ack:' || qid), 'R9 asiakkaan kuittaus ennallaan');

  if nid is null then
    perform public.t102_ck(false, 'C1 ei ilmoitusriviä, claimia ei ajeta');
  else
    create temp table t102_hold on commit drop as
      select id, next_attempt_at from booking.email_outbox where status in ('pending', 'failed') and id <> nid;
    update booking.email_outbox set next_attempt_at = now() + interval '1 day' where id in (select id from t102_hold);
    update booking.email_outbox set next_attempt_at = now() - interval '1 second' where id = nid;
    cl := booking.email_outbox_claim(5);
    update booking.email_outbox e set next_attempt_at = h.next_attempt_at from t102_hold h where e.id = h.id;
    select e into rowj from jsonb_array_elements(cl) e where e ->> 'kind' = 'business_quote_notify' and (e -> 'quote' ->> 'id')::bigint = qid;
    perform public.t102_ck(jsonb_array_length(cl) = 1 and rowj is not null, 'C1 claim palauttaa vain tämän ilmoituksen');
    perform public.t102_ck(rowj ->> 'to' = 'savusauna@saunotus.fi' and rowj ->> 'to_name' = 'Joonas' and rowj ->> 'reply_to' = 'maija@example.test' and rowj ->> 'locale' = 'fi', 'C2 vastaanottaja ja reply-to');
    perform public.t102_ck(rowj -> 'quote' ->> 'company_name' = 'Sipoon Testi Oy' and rowj -> 'quote' ->> 'contact_name' = 'Maija Meikäläinen' and rowj -> 'quote' ->> 'email' = 'maija@example.test' and rowj -> 'quote' ->> 'phone' = '040 123 4567', 'C3 quote: yritys, yhteyshenkilö, sähköposti, puhelin');
    perform public.t102_ck((rowj -> 'quote' ->> 'persons')::int = 12 and rowj -> 'quote' -> 'offerings' = p -> 'offerings' and rowj -> 'quote' ->> 'offering_other' = 'yrityssaunaretki', 'C4 quote: henkilömäärä ja palvelut');
    perform public.t102_ck(rowj -> 'quote' ->> 'preferred_when' = 'ensi viikon perjantai' and rowj -> 'quote' ->> 'message' = 'toive metsäkävelystä' and rowj -> 'quote' ->> 'locale' = 'en' and (rowj -> 'quote' ->> 'created_at')::timestamptz = (p ->> 'created_at')::timestamptz and (rowj -> 'quote' ->> 'id')::bigint = qid, 'C5 quote: ajankohta, viesti, kieli, lähetysaika, tunnus');
  end if;

  log := current_setting('t102.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
