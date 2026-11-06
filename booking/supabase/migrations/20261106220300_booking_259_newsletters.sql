-- booking_259: bot-authored newsletters, human-only review/dispatch.
-- Generated with supabase migration new; timestamp ordered after reserved booking_257.
-- Bottiavustus: DEV first, production second; do not merge before both succeed.
-- Rollback: ../rollbacks/20261106220300_booking_259_ROLLBACK.sql
set local lock_timeout = '5s';

create table booking.newsletters (
  id bigint generated always as identity primary key,
  subject_fi text not null check (length(btrim(subject_fi)) between 1 and 200),
  subject_en text not null check (length(btrim(subject_en)) between 1 and 200),
  body_fi text not null check (length(btrim(body_fi)) between 1 and 16000),
  body_en text not null check (length(btrim(body_en)) between 1 and 16000),
  style jsonb not null,
  segment text not null check (segment in ('all','training','treatment','event','session_only','gift_buyers','christmas_gift_buyers')),
  language text not null default 'all' check (language in ('all','fi','en')),
  suggested_send_at timestamptz,
  state text not null default 'draft' check (state in ('draft','previewed','sent')),
  version integer not null default 1,
  preview_token uuid, preview_at timestamptz, preview_signature text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table booking.newsletter_logs (
  id bigint generated always as identity primary key,
  newsletter_id bigint not null unique references booking.newsletters(id),
  subject_fi text not null, subject_en text not null,
  body_fi text not null, body_en text not null, style jsonb not null,
  segment text not null, language text not null,
  recipient_count integer not null check (recipient_count between 1 and 5000),
  queued_count integer not null default 0 check (queued_count between 0 and 5000),
  created_by uuid not null, created_at timestamptz not null default now()
);
comment on table booking.newsletter_logs is 'Immutable newsletter send snapshot and counts only. No recipient names or addresses. sent means handed to existing outbox, not confirmed delivery.';
alter table booking.newsletters enable row level security;
alter table booking.newsletter_logs enable row level security;
revoke all on booking.newsletters, booking.newsletter_logs from public, anon, authenticated, service_role;
create index newsletter_drafts_updated_idx on booking.newsletters(updated_at desc, id desc);
create index newsletter_logs_created_idx on booking.newsletter_logs(created_at desc);
-- Store only internal identifiers in outbox payload. Existing dedupe_key UNIQUE enforces log+customer deduplication.
create index newsletter_outbox_log_idx on booking.email_outbox ((payload->>'newsletter_log_id')) where kind='newsletter';

do $$ declare def text; begin
  select pg_get_constraintdef(oid) into def from pg_constraint
    where conrelid='booking.email_outbox'::regclass and conname='email_outbox_kind_check';
  if def is null or position('ARRAY[' in def)=0 then raise exception 'booking_259: unknown outbox kind constraint'; end if;
  execute 'alter table booking.email_outbox drop constraint email_outbox_kind_check';
  execute 'alter table booking.email_outbox add constraint email_outbox_kind_check ' || replace(def, 'ARRAY[', 'ARRAY[''newsletter''::text, ');
end $$;

-- Helpers are in the non-public booking schema; no exposed public wrapper or direct grants.
create function booking._newsletter_validate(p_data jsonb) returns void
language plpgsql immutable set search_path='' as $$
declare k text; s jsonb := p_data->'style'; begin
  if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Invalid newsletter'; end if;
  for k in select jsonb_object_keys(p_data) loop
    if k not in ('subject_fi','subject_en','body_fi','body_en','style','segment','language','suggested_send_at') then
      raise exception 'Unknown newsletter field';
    end if;
  end loop;
  foreach k in array array['subject_fi','subject_en','body_fi','body_en'] loop
    if jsonb_typeof(p_data->k) is distinct from 'string' or length(btrim(p_data->>k)) < 1
      or length(p_data->>k) > (case when k like 'subject_%' then 200 else 16000 end) then
      raise exception 'Invalid newsletter text';
    end if;
    if k like 'subject_%' and (p_data->>k) ~ E'[\r\n]' then raise exception 'Invalid subject'; end if;
  end loop;
  if jsonb_typeof(s) is distinct from 'object' or s->>'layout' is null
     or s->>'layout' not in ('letter','editorial') then raise exception 'Invalid newsletter style'; end if;
  for k in select jsonb_object_keys(s) loop
    if k not in ('layout','background','foreground','accent','image_url','cta_url','cta_fi','cta_en') then raise exception 'Unknown style field'; end if;
    if jsonb_typeof(s->k) is distinct from 'string' then raise exception 'Invalid style value'; end if;
    if k in ('background','foreground','accent') and (s->>k) !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Invalid style color'; end if;
    if k in ('image_url','cta_url') and ((s->>k) !~ '^https://[a-zA-Z0-9][^[:space:]<>"\x27]*$' or (s->>k) ~ '@' or length(s->>k)>1000) then raise exception 'Invalid style URL'; end if;
    if k in ('cta_fi','cta_en') and length(s->>k) not between 1 and 100 then raise exception 'Invalid CTA'; end if;
  end loop;
  if s ? 'cta_url' and (not s ? 'cta_fi' or not s ? 'cta_en') then raise exception 'CTA requires FI and EN labels'; end if;
  if p_data->>'segment' is null or p_data->>'segment' not in ('all','training','treatment','event','session_only','gift_buyers','christmas_gift_buyers')
     or coalesce(p_data->>'language','all') not in ('all','fi','en') then raise exception 'Invalid newsletter segment'; end if;
end $$;

create function booking._newsletter_recipients(p_segment text, p_language text)
returns table(customer_id bigint, locale text, email_hash text)
language sql stable security definer set search_path='' as $$
  with visits as (
    select o.customer_id,
      bool_or(p.category='training' and not exists (
        select 1 from booking.reservations future join kb.products fp on fp.id=future.product_id
        where future.order_id=o.id and fp.category='training' and future.hidden_at is null
          and future.status in ('confirmed','pending') and future.ends_at>now()
      )) as training,
      bool_or(p.category in ('treatment','ritual','ceremony')) as treatment,
      bool_or(p.category='event') as event,
      bool_or(pc.sale_kind in ('public_shift','private_shift')) as session
    from booking.reservations r join booking.orders o on o.id=r.order_id
    join kb.products p on p.id=r.product_id left join booking.product_config pc on pc.product_id=r.product_id
    where r.hidden_at is null and r.status in ('confirmed','completed') and r.ends_at<=now()
      and o.status in ('confirmed','completed') and o.payment_status<>'refunded'
    group by o.customer_id
  ), gifts as (
    select coalesce(g.buyer_customer_id,o.customer_id) as customer_id,
      bool_or(extract(month from coalesce(o.created_at,g.created_at) at time zone 'Europe/Helsinki') in (11,12)
        and extract(year from coalesce(o.created_at,g.created_at) at time zone 'Europe/Helsinki')
          < extract(year from now() at time zone 'Europe/Helsinki')) as christmas
    from booking.gift_cards g left join booking.orders o on o.id=g.purchase_order_id
    where g.issuer in ('own','johku') and g.status in ('active','used','expired') and not coalesce(g.complimentary,false)
      and (o.id is null or (o.status in ('confirmed','completed') and o.payment_status<>'refunded'))
    group by coalesce(g.buyer_customer_id,o.customer_id)
  ), eligible as (
    select c.id, lower(btrim(c.email)) as email,
      case when coalesce(nullif(c.language,''),(select nullif(o.locale,'') from booking.orders o
        where o.customer_id=c.id and o.status in ('confirmed','completed') order by o.created_at desc,o.id desc limit 1),'fi')='en' then 'en' else 'fi' end as lang
    from booking.customers c left join visits v on v.customer_id=c.id left join gifts g on g.customer_id=c.id
    where c.marketing_consent is true and c.anonymized_at is null and booking._valid_email(c.email)
      and c.unsubscribe_token is not null
      and case p_segment when 'all' then true when 'training' then coalesce(v.training,false)
        when 'treatment' then coalesce(v.treatment,false) when 'event' then coalesce(v.event,false)
        when 'session_only' then coalesce(v.session,false) and not coalesce(v.training,false) and not coalesce(v.treatment,false) and not coalesce(v.event,false)
        when 'gift_buyers' then g.customer_id is not null when 'christmas_gift_buyers' then coalesce(g.christmas,false) else false end
  ), unique_mail as (
    select distinct on (e.email) e.* from eligible e order by e.email,e.id
  ) select e.id,e.lang,md5(e.email) from unique_mail e where p_language='all' or e.lang=p_language;
$$;

create function booking._newsletter_save(p_id bigint,p_data jsonb,p_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n booking.newsletters; begin
  perform booking._newsletter_validate(p_data);
  if p_id is null then
    insert into booking.newsletters(subject_fi,subject_en,body_fi,body_en,style,segment,language,suggested_send_at)
    values(p_data->>'subject_fi',p_data->>'subject_en',p_data->>'body_fi',p_data->>'body_en',p_data->'style',p_data->>'segment',coalesce(p_data->>'language','all'),(p_data->>'suggested_send_at')::timestamptz) returning * into n;
  else
    select * into n from booking.newsletters where id=p_id for update;
    if not found or n.state='sent' or p_version is distinct from n.version then perform booking._err('newsletter_conflict','Luonnos muuttui tai on jo lähetetty. Lataa uudelleen.'); end if;
    update booking.newsletters set subject_fi=p_data->>'subject_fi',subject_en=p_data->>'subject_en',body_fi=p_data->>'body_fi',body_en=p_data->>'body_en',style=p_data->'style',segment=p_data->>'segment',language=coalesce(p_data->>'language','all'),suggested_send_at=(p_data->>'suggested_send_at')::timestamptz,
      state='draft',version=version+1,preview_token=null,preview_at=null,preview_signature=null,updated_at=now() where id=p_id returning * into n;
  end if;
  return to_jsonb(n)-'preview_signature'-'preview_token';
end $$;

-- Service-role bots can ONLY author a draft. No admin/send permission is granted here.
create function booking.svc_newsletter_save(p_id bigint,p_data jsonb,p_version integer default null)
returns jsonb language sql security definer set search_path='' as $$
  select booking._newsletter_save(p_id,p_data,p_version);
$$;
create function booking.admin_newsletter_save(p_id bigint,p_data jsonb,p_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n booking.newsletters; k text; begin
  perform booking._require_permission('messages.edit');
  if p_data is null or jsonb_typeof(p_data)<>'object' then raise exception 'Invalid newsletter'; end if;
  for k in select jsonb_object_keys(p_data) loop
    if k not in ('subject_fi','subject_en','body_fi','body_en','segment','language') then raise exception 'Only text and audience are editable'; end if;
  end loop;
  select * into n from booking.newsletters where id=p_id for update;
  if not found then perform booking._err('not_found','Uutiskirjettä ei löydy'); end if;
  return booking._newsletter_save(p_id,jsonb_build_object('subject_fi',n.subject_fi,'subject_en',n.subject_en,'body_fi',n.body_fi,'body_en',n.body_en,'style',n.style,'segment',n.segment,'language',n.language,'suggested_send_at',n.suggested_send_at)||p_data,p_version);
end $$;

create function booking.admin_newsletters_list() returns jsonb
language plpgsql stable security definer set search_path='' as $$ begin
  perform booking._require_permission('messages.edit');
  return coalesce((select jsonb_agg(to_jsonb(n)-'preview_signature'-'preview_token' || jsonb_build_object('delivery',
    (select jsonb_build_object('recipient_count',l.recipient_count,'queued_count',l.queued_count,'created_at',l.created_at,
      'sent',(select count(*) from booking.email_outbox e where e.kind='newsletter' and e.payload->>'newsletter_log_id'=l.id::text and e.status='sent'),
      'failed',(select count(*) from booking.email_outbox e where e.kind='newsletter' and e.payload->>'newsletter_log_id'=l.id::text and e.status='failed'),
      'skipped',(select count(*) from booking.email_outbox e where e.kind='newsletter' and e.payload->>'newsletter_log_id'=l.id::text and e.status in ('skipped','dry_run')))
    from booking.newsletter_logs l where l.newsletter_id=n.id)) order by n.updated_at desc,n.id desc)
    from (select * from booking.newsletters order by updated_at desc,id desc limit 100) n),'[]'::jsonb);
end $$;

create function booking.admin_newsletter_dispatch(p_id bigint,p_version integer,p_confirm boolean default false,p_preview_token uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n booking.newsletters; ids bigint[]; langs text[]; sig text; token uuid; cnt integer; log_id bigint; queued integer; mode text; begin
  -- Even a service-role bot must not be able to send with this function.
  if auth.uid() is null or coalesce(booking._jwt_role(),'')<>'authenticated' then perform booking._err('forbidden','Lähetys vain kirjautuneesta hallinnasta'); end if;
  perform booking._require_permission('messages.edit');
  select * into n from booking.newsletters where id=p_id for update;
  if not found then perform booking._err('not_found','Uutiskirjettä ei löydy'); end if;
  if n.state='sent' then return jsonb_build_object('ok',true,'sent',true,'already_sent',true); end if;
  if p_version is distinct from n.version then perform booking._err('newsletter_conflict','Luonnos muuttui. Lataa uudelleen.'); end if;
  select array_agg(r.customer_id order by r.customer_id),array_agg(r.locale order by r.customer_id),
    md5(coalesce(string_agg(r.customer_id::text||':'||r.locale||':'||r.email_hash,',' order by r.customer_id),'')),count(*)
    into ids,langs,sig,cnt from booking._newsletter_recipients(n.segment,n.language) r;
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
  insert into booking.email_outbox(kind,locale,dedupe_key,payload,status)
  select 'newsletter',langs[i],'newsletter:'||log_id::text||':'||ids[i]::text,
    jsonb_build_object('newsletter_log_id',log_id,'customer_id',ids[i]),'pending'
    from generate_subscripts(ids,1) i on conflict(dedupe_key) do nothing;
  get diagnostics queued=row_count;
  update booking.newsletter_logs set queued_count=queued where id=log_id;
  update booking.newsletters set state='sent',preview_token=null,preview_signature=null,updated_at=now() where id=n.id;
  return jsonb_build_object('ok',true,'sent',true,'recipient_count',cnt,'queued_count',queued,'mode',mode);
end $$;

-- Called by the existing sender immediately before each delivery: recheck consent and anonymisation.
-- No need to replace/rename email_outbox_claim (preserves booking_257 and its dependencies).
create function booking.email_newsletter_payload(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e booking.email_outbox; c booking.customers; l booking.newsletter_logs; loc text; site text; begin
  select * into e from booking.email_outbox where id=p_id and kind='newsletter' and status='sending';
  if not found then return jsonb_build_object('allowed',false); end if;
  select * into c from booking.customers where id=(e.payload->>'customer_id')::bigint;
  if c.id is null or c.marketing_consent is not true or c.anonymized_at is not null or not booking._valid_email(c.email) or c.unsubscribe_token is null then return jsonb_build_object('allowed',false); end if;
  select * into l from booking.newsletter_logs where id=(e.payload->>'newsletter_log_id')::bigint;
  if not found then return jsonb_build_object('allowed',false); end if;
  loc:=case when e.locale='en' then 'en' else 'fi' end;
  site:=coalesce(booking._setting('site_base_url')#>>'{}','');
  if site !~ '^https://[^[:space:]]+$' then return jsonb_build_object('allowed',false); end if;
  return jsonb_build_object('allowed',true,'to',c.email,'subject',case when loc='en' then l.subject_en else l.subject_fi end,
    'body',case when loc='en' then l.body_en else l.body_fi end,'style',l.style,'locale',loc,
    'unsubscribe_url',site||case when loc='en' then '/en/order/' else coalesce(booking._setting('order_page_path')#>>'{}','/tilaus/') end||'?u='||c.unsubscribe_token::text);
end $$;

-- Revoke every direct/default grant; explicitly allow only intended RPC boundaries.
do $$ declare f regprocedure; begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='booking' and p.proname in ('_newsletter_validate','_newsletter_recipients','_newsletter_save','svc_newsletter_save','admin_newsletter_save','admin_newsletters_list','admin_newsletter_dispatch','email_newsletter_payload')
  loop execute format('revoke all on function %s from public,anon,authenticated,service_role',f); end loop;
end $$;
grant execute on function booking.svc_newsletter_save(bigint,jsonb,integer) to service_role;
grant execute on function booking.email_newsletter_payload(bigint) to service_role;
grant execute on function booking.admin_newsletters_list() to authenticated,service_role;
grant execute on function booking.admin_newsletter_save(bigint,jsonb,integer) to authenticated,service_role;
-- Intentionally no service_role dispatch grant: a staff JWT + messages.edit are mandatory.
grant execute on function booking.admin_newsletter_dispatch(bigint,integer,boolean,uuid) to authenticated;
notify pgrst,'reload schema';
