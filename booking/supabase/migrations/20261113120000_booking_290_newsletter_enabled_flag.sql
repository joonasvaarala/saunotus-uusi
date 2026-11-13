-- booking_290: uutiskirjeen oma kytkin newsletter_enabled (booking.settings, oletus false).
-- Taustaa: docs/claude/uutiskirje-tila.md kohta 3.3 ja 5. Resend on PRODissa live, joten ilman kytkintä admin_newsletter_dispatch olisi teknisesti
-- käytettävissä heti, kun joku, jolla on messages.edit, kutsuu RPC:tä. Malli: _customer_flag (booking_285).
--   * Kytkin lisätään arvolla false (on conflict do nothing): migraatio EI muuta jo asetettua arvoa. Kytkimen avaa vain Joonaksen luvalla (admin_set_setting).
--   * admin_newsletter_dispatch(confirm=true) antaa virheen newsletter_disabled, eikä email_outbox- tai newsletter_logs-rivejä synny. Esikatselu sallitaan.
--   * email_newsletter_payload palauttaa allowed:false, jolloin jonossa jo olevatkaan rivit eivät lähde (send-emails ohittaa ne tilalla skipped).
--   * admin_newsletter_enabled(): hallinnan käyttöliittymän tilatieto (messages.edit).
-- Muuttaa vain nämä kaksi funktiota (rungot muuten samat kuin booking_259). Ennakkotarkistus: nykyisten funktioiden prosrc md5 (sama kuin 259/262 PRODissa).
-- Rollback: ../rollbacks/20261113120000_booking_290_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
begin
  if to_regprocedure('booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)') is null or to_regprocedure('booking.email_newsletter_payload(bigint)') is null then
    raise exception 'booking_290: booking_259 puuttuu. Ei muutoksia.'; end if;
  if (select md5(prosrc) from pg_catalog.pg_proc where oid = 'booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)'::regprocedure) <> '0274fee6e58fbfbc702a539ca3be3f90'
     or (select md5(prosrc) from pg_catalog.pg_proc where oid = 'booking.email_newsletter_payload(bigint)'::regprocedure) <> '4854445d21ab30783bd3afdcdbf64356' then
    raise exception 'booking_290: admin_newsletter_dispatch tai email_newsletter_payload poikkeaa odotetusta (booking_259). Ei muutoksia.'; end if;
end $pre$;

insert into booking.settings(key, value, description, is_public) values
  ('newsletter_enabled', 'false'::jsonb, 'booking_290: uutiskirjeiden lähetys hallinnasta (admin_newsletter_dispatch confirm=true ja email_newsletter_payload). Oletus false. Käyttöönotto vaatii Joonaksen erillisen luvan; ensimmäinen lähetys vain testisegmentille.', false)
on conflict (key) do nothing;

create or replace function booking._newsletter_flag(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.value = 'true'::jsonb from booking.settings s where s.key = p_key), false)
$$;
revoke all on function booking._newsletter_flag(text) from public, anon, authenticated, service_role;

create or replace function booking.admin_newsletter_enabled() returns boolean
language plpgsql stable security definer set search_path = '' as $$ begin
  perform booking._require_permission('messages.edit');
  return booking._newsletter_flag('newsletter_enabled');
end $$;
revoke all on function booking.admin_newsletter_enabled() from public, anon, service_role;
grant execute on function booking.admin_newsletter_enabled() to authenticated;

create or replace function booking.admin_newsletter_dispatch(p_id bigint,p_version integer,p_confirm boolean default false,p_preview_token uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n booking.newsletters; ids bigint[]; langs text[]; fingerprints text[]; sig text; token uuid; cnt integer; log_id bigint; queued integer; mode text; begin
  -- Even a service-role bot must not be able to send with this function.
  if auth.uid() is null or coalesce(booking._jwt_role(),'')<>'authenticated' then perform booking._err('forbidden','Lähetys vain kirjautuneesta hallinnasta'); end if;
  perform booking._require_permission('messages.edit');
  -- booking_290: oma kytkin. Kun false, lähetys (confirm=true) estetään ennen kuin mitään kirjoitetaan. Esikatselu (confirm=false) sallitaan.
  if coalesce(p_confirm,false) and not booking._newsletter_flag('newsletter_enabled') then perform booking._err('newsletter_disabled','Uutiskirjeiden lähetys ei ole käytössä'); end if;
  if not exists(select 1 from pg_catalog.pg_trigger t where t.tgrelid='booking.customers'::regclass
    and t.tgname='newsletter_capture_general_optout' and not t.tgisinternal and t.tgenabled in ('O','A')
    and t.tgfoid=to_regprocedure('booking._newsletter_capture_general_optout()')) then perform booking._err('newsletter_capture_required','Uutiskirjeiden peruutussuoja ei ole käytössä'); end if;
  select * into n from booking.newsletters where id=p_id for update;
  if not found then perform booking._err('not_found','Uutiskirjettä ei löydy'); end if;
  if n.state='sent' then return jsonb_build_object('ok',true,'sent',true,'already_sent',true); end if;
  if p_version is distinct from n.version then perform booking._err('newsletter_conflict','Luonnos muuttui. Lataa uudelleen.'); end if;
  select array_agg(r.customer_id order by r.customer_id),array_agg(r.locale order by r.customer_id),array_agg(r.email_hash order by r.customer_id),
    md5(coalesce(string_agg(r.customer_id::text||':'||r.locale||':'||r.email_hash,',' order by r.customer_id),'')),count(*)
    into ids,langs,fingerprints,sig,cnt from booking._newsletter_recipients(n.segment,n.language) r;
  if cnt>5000 then perform booking._err('too_many','Enintään 5000 vastaanottajaa. Rajaa segmenttiä tai kieltä.'); end if;
  if not coalesce(p_confirm,false) then
    token:=gen_random_uuid();
    update booking.newsletters set state='previewed',preview_at=now(),preview_token=token,preview_signature=sig where id=n.id;
    return jsonb_build_object('ok',true,'sent',false,'recipient_count',cnt,'fi_count',coalesce((select count(*) from unnest(langs) x where x='fi'),0),'en_count',coalesce((select count(*) from unnest(langs) x where x='en'),0),'preview_token',token,'version',n.version);
  end if;
  if n.state<>'previewed' or p_preview_token is null or p_preview_token is distinct from n.preview_token
    or n.preview_at<now()-interval '30 minutes' or sig is distinct from n.preview_signature then
    perform booking._err('newsletter_preview_required','Vastaanottajat tai luonnos muuttuivat. Esikatsele uudelleen.'); end if;
  if cnt<1 then perform booking._err('no_recipients','Ei vastaanottajia'); end if;
  select i.mode into mode from booking.integration_config i where i.key='resend';
  if coalesce(mode,'off')='off' then perform booking._err('email_disabled','Sähköpostilähetys on pois käytöstä'); end if;
  insert into booking.newsletter_logs(newsletter_id,subject_fi,subject_en,body_fi,body_en,style,segment,language,recipient_count,created_by)
  values(n.id,n.subject_fi,n.subject_en,n.body_fi,n.body_en,n.style,n.segment,n.language,cnt,auth.uid()) returning id into log_id;
  insert into booking.newsletter_optout_tokens(address_fingerprint)
    select distinct x from unnest(fingerprints) x on conflict do nothing;
  insert into booking.email_outbox(kind,locale,dedupe_key,payload,status)
  select 'newsletter',langs[i],'newsletter:'||log_id::text||':'||ids[i]::text,
    jsonb_build_object('newsletter_log_id',log_id,'customer_id',ids[i],'address_fingerprint',fingerprints[i]),'pending'
    from generate_subscripts(ids,1) i on conflict(dedupe_key) do nothing;
  get diagnostics queued=row_count;
  update booking.newsletter_logs set queued_count=queued where id=log_id;
  update booking.newsletters set state='sent',preview_token=null,preview_signature=null,updated_at=now() where id=n.id;
  return jsonb_build_object('ok',true,'sent',true,'recipient_count',cnt,'queued_count',queued,'mode',mode);
end $$;

create or replace function booking.email_newsletter_payload(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e booking.email_outbox; c booking.customers; l booking.newsletter_logs; loc text; site text; expected text; optout uuid; begin
  -- booking_290: kytkin pois → mikään jonossa oleva rivi ei lähde.
  if not booking._newsletter_flag('newsletter_enabled') then return jsonb_build_object('allowed',false); end if;
  if not exists(select 1 from pg_catalog.pg_trigger t where t.tgrelid='booking.customers'::regclass
    and t.tgname='newsletter_capture_general_optout' and not t.tgisinternal and t.tgenabled in ('O','A')
    and t.tgfoid=to_regprocedure('booking._newsletter_capture_general_optout()')) then return jsonb_build_object('allowed',false); end if;
  select * into e from booking.email_outbox where id=p_id and kind='newsletter' and status='sending';
  if not found then return jsonb_build_object('allowed',false); end if;
  select * into c from booking.customers where id=(e.payload->>'customer_id')::bigint;
  if c.id is null or c.marketing_consent is not true or c.anonymized_at is not null or not booking._valid_email(c.email) then return jsonb_build_object('allowed',false); end if;
  expected:=e.payload->>'address_fingerprint';
  if expected is null or expected !~ '^[0-9a-f]{64}$'
     or booking._newsletter_fingerprint(c.email) is distinct from expected
     or booking._newsletter_address_blocked(expected,c.email) then return jsonb_build_object('allowed',false); end if;
  select t.token into optout from booking.newsletter_optout_tokens t where t.address_fingerprint=expected;
  if optout is null then return jsonb_build_object('allowed',false); end if;
  select * into l from booking.newsletter_logs where id=(e.payload->>'newsletter_log_id')::bigint;
  if not found then return jsonb_build_object('allowed',false); end if;
  loc:=case when e.locale='en' then 'en' else 'fi' end;
  site:=coalesce(booking._setting('site_base_url')#>>'{}','');
  if site !~ '^https://[^[:space:]]+$' then return jsonb_build_object('allowed',false); end if;
  return jsonb_build_object('allowed',true,'to',lower(btrim(c.email)),'subject',case when loc='en' then l.subject_en else l.subject_fi end,
    'body',case when loc='en' then l.body_en else l.body_fi end,'style',l.style,'locale',loc,
    'unsubscribe_url',rtrim(site,'/')||'/hallinta/newsletter-unsubscribe.html#token='||optout::text||'&lang='||loc);
end $$;

-- create or replace säilyttää 259:n oikeudet (vain authenticated / service_role). Varmistus:
do $post$
begin
  if has_function_privilege('anon', 'booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)', 'execute')
     or has_function_privilege('service_role', 'booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)', 'execute')
     or has_function_privilege('anon', 'booking.email_newsletter_payload(bigint)', 'execute')
     or has_function_privilege('authenticated', 'booking.email_newsletter_payload(bigint)', 'execute')
     or not has_function_privilege('service_role', 'booking.email_newsletter_payload(bigint)', 'execute')
     or not has_function_privilege('authenticated', 'booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid)', 'execute') then
    raise exception 'booking_290: funktioiden oikeudet poikkeavat odotetusta'; end if;
end $post$;
