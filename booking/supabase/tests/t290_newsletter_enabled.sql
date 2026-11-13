-- DISPOSABLE LOCAL DATABASE ONLY (rollback-only). booking_290: newsletter_enabled-kytkin, booking_291: peruutuslistojen yhdistäminen.
-- Synteettinen data (example.test). Ajo: psql -X -v ON_ERROR_STOP=1 -1 -f t290_newsletter_enabled.sql ; kaikki muutokset perutaan.
begin;
create function pg_temp.ck(ok boolean,label text) returns void language plpgsql as $$begin
  if ok is not true then raise exception 'FAIL: %',label; end if;
  raise notice 'PASS: %',label;
end$$;
do $test$
declare
  uid uuid:=gen_random_uuid(); ids bigint[]:='{}'; c bigint; x jsonb; y jsonb; draft jsonb; data jsonb; tok uuid; nid bigint; v int; eid bigint;
  base_n int; blocked boolean; n int; fp text; i int;
begin
  insert into auth.users(id,email) values(uid,'n290-manager@example.test');
  insert into booking.staff(user_id,email,name,role) values(uid,'n290-manager@example.test','N290 test','manager');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated')::text,true);
  update booking.customers set marketing_consent=false where marketing_consent;
  update booking.integration_config set mode='dry_run' where key='resend';
  -- ---- migraatio ei avaa kytkintä: oletus false (rivi poistetaan ja lisätään migraation tavalla) ----
  perform pg_temp.ck((select value from booking.settings where key='newsletter_enabled') is not null,'newsletter_enabled-rivi on olemassa');
  perform pg_temp.ck(not coalesce((select is_public from booking.settings where key='newsletter_enabled'),true),'newsletter_enabled ei ole julkinen asetus');
  delete from booking.settings where key='newsletter_enabled';
  perform pg_temp.ck(booking._newsletter_flag('newsletter_enabled') is false,'puuttuva kytkin tulkitaan falseksi');
  insert into booking.settings(key,value,is_public) values('newsletter_enabled','false'::jsonb,false);
  perform pg_temp.ck(not has_function_privilege('authenticated','booking._newsletter_flag(text)','execute') and not has_function_privilege('anon','booking._newsletter_flag(text)','execute'),'kytkinapufunktio ei ole kutsuttavissa');
  perform pg_temp.ck(has_function_privilege('authenticated','booking.admin_newsletter_enabled()','execute') and not has_function_privilege('anon','booking.admin_newsletter_enabled()','execute'),'tilafunktio vain kirjautuneille');
  perform pg_temp.ck(booking.admin_newsletter_enabled() is false,'tilafunktio kertoo false');

  for i in 1..4 loop
    insert into booking.customers(name,email,marketing_consent,marketing_consent_at,language)
      values('n290-'||i,'n290-'||i||'@example.test',true,now(),'fi') returning id into c;
    ids:=array_append(ids,c);
  end loop;
  data:='{"subject_fi":"Testi","subject_en":"Test","body_fi":"Teksti","body_en":"Text","style":{"layout":"letter"},"segment":"all","language":"all"}'::jsonb;
  draft:=booking.svc_newsletter_save(null,data);nid:=(draft->>'id')::bigint;v:=(draft->>'version')::int;
  select count(*) into base_n from booking.email_outbox;

  -- ---- kytkin false: esikatselu sallitaan, lähetys ei ----
  x:=booking.admin_newsletter_dispatch(nid,v,false);tok:=(x->>'preview_token')::uuid;
  perform pg_temp.ck((x->>'recipient_count')::int=4,'esikatselu toimii kytkimen ollessa false');
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,tok);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'dispatch(confirm=true) antaa virheen kun kytkin on false');
  perform pg_temp.ck((select count(*) from booking.email_outbox)=base_n and not exists(select 1 from booking.newsletter_logs) and (select state from booking.newsletters where id=nid)='previewed','ei outbox-rivejä, ei lokia, tila ei muutu');
  begin perform booking.admin_newsletter_dispatch(nid,v,true,tok);exception when others then get stacked diagnostics fp = PG_EXCEPTION_DETAIL; end;
  perform pg_temp.ck(fp='newsletter_disabled','virhekoodi on newsletter_disabled');
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,true,null);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'ilman esikatselutokenia ei myöskään lähde');

  -- ---- kytkin auki: lähetys jonottaa ----
  update booking.settings set value='true'::jsonb where key='newsletter_enabled';
  perform pg_temp.ck(booking.admin_newsletter_enabled() is true,'tilafunktio kertoo true');
  y:=booking.admin_newsletter_dispatch(nid,v,true,tok);
  perform pg_temp.ck((y->>'queued_count')::int=4 and (select count(*) from booking.email_outbox)=base_n+4,'kytkin true: neljä outbox-riviä');

  -- ---- email_newsletter_payload: kytkin false -> allowed:false vaikka rivi on jo jonossa ----
  select id into eid from booking.email_outbox where kind='newsletter' and payload->>'customer_id'=ids[1]::text order by id desc limit 1;
  update booking.email_outbox set status='sending' where id=eid;
  perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='true','payload sallittu kun kytkin on true');
  update booking.settings set value='false'::jsonb where key='newsletter_enabled';
  perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='false' and not booking.email_newsletter_payload(eid)?'to','payload allowed:false ja ilman osoitetta kun kytkin on false');
  update booking.settings set value='"true"'::jsonb where key='newsletter_enabled';
  perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='false','vain boolean true avaa kytkimen (merkkijono "true" ei)');
  update booking.settings set value='true'::jsonb where key='newsletter_enabled';

  -- ---- botti ei voi lähettää kytkimen ollessa auki ----
  perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','service_role')::text,true);
  blocked:=false;begin perform booking.admin_newsletter_dispatch(nid,v,false);exception when sqlstate 'BK001' then blocked:=true;end;
  perform pg_temp.ck(blocked,'service_role ei voi lähettää/esikatsella kytkimen ollessa auki');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated')::text,true);

  -- ---- booking_291: osoite vain marketing_suppressions-taulussa ----
  draft:=booking.svc_newsletter_save(null,data||'{"subject_fi":"Toinen"}');nid:=(draft->>'id')::bigint;v:=(draft->>'version')::int;
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('all','all'))=4,'ennen suppressiota 4 vastaanottajaa');
  perform pg_temp.ck(not exists(select 1 from booking.newsletter_suppressions where address_fingerprint=booking._email_hash('n290-2@example.test')),'osoite ei ole newsletter_suppressions-taulussa');
  insert into booking.marketing_suppressions(email_hash,reason,source) values(booking._email_hash('N290-2@Example.test '),'merged_unsubscribed','t290');
  perform pg_temp.ck(booking._newsletter_address_blocked(booking._newsletter_fingerprint('n290-2@example.test'),'n290-2@example.test'),'osoite on estetty pelkästä marketing_suppressions-taulusta');
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('all','all'))=3 and not exists(select 1 from booking._newsletter_recipients('all','all') r where r.customer_id=ids[2]),'osoite vain marketing_suppressions-taulussa: ei vastaanottaja');
  x:=booking.admin_newsletter_dispatch(nid,v,false);tok:=(x->>'preview_token')::uuid;
  perform pg_temp.ck((x->>'recipient_count')::int=3,'esikatselun määrä ei sisällä suppressoitua osoitetta');
  y:=booking.admin_newsletter_dispatch(nid,v,true,tok);
  perform pg_temp.ck((y->>'queued_count')::int=3 and not exists(select 1 from booking.email_outbox e where e.kind='newsletter' and e.payload->>'customer_id'=ids[2]::text and e.payload->>'newsletter_log_id'=(select max(id)::text from booking.newsletter_logs)),'lähetys ei jonota suppressoitua osoitetta');
  -- suppressio ilmestyy jonotuksen jälkeen (esim. anonymisointi/yhdistäminen): tuore tarkistus pysäyttää
  select id into eid from booking.email_outbox where kind='newsletter' and payload->>'customer_id'=ids[3]::text and payload->>'newsletter_log_id'=(select max(id)::text from booking.newsletter_logs);
  update booking.email_outbox set status='sending' where id=eid;
  perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='true','jonossa oleva rivi sallittu ennen suppressiota');
  insert into booking.marketing_suppressions(email_hash,reason,source) values(booking._email_hash('n290-3@example.test'),'anonymized','t290');
  perform pg_temp.ck(booking.email_newsletter_payload(eid)->>'allowed'='false','marketing_suppressions jonotuksen jälkeen estää lähetyksen (payload allowed:false)');
  -- molemmat taulut toimivat edelleen
  insert into booking.newsletter_suppressions(address_fingerprint) values(booking._newsletter_fingerprint('n290-4@example.test'));
  perform pg_temp.ck((select count(*) from booking._newsletter_recipients('all','all'))=1,'newsletter_suppressions estää edelleen (jäljellä 1 vastaanottaja)');
  perform pg_temp.ck(not booking._newsletter_address_blocked(booking._newsletter_fingerprint('n290-1@example.test'),'n290-1@example.test'),'suppressoimaton osoite ei ole estetty');
end
$test$;
rollback;
