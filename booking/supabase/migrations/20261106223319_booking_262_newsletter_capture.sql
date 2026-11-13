-- PROD sxbofnuisemspgquoxyv supabase_migrations.schema_migrations version 20261106223319 name booking_262_newsletter_capture (1 lauseketta)
-- booking_262: NON-MUTATING verification/provenance migration after259.
-- Capture was reserved as262. Implementation moved into259 for ONE official atomic
-- apply_migration transaction (DDL + customer-write lock + hook + backfill + history).
--262 records normally through apply_migration; it DOES NOT repeat installation/backfill.
-- HOLD: no execution approval. No manual history rows, internal BEGIN/COMMIT or raw SQL install.
-- Intentionally SELECT/catalog checks only; failures require review, never automatic repair.
do $verify$
declare item record;fn record; role_name text; target regclass;actual_cols text[];
begin
 foreach role_name in array array['anon','authenticated','service_role'] loop
  foreach target in array array[to_regclass('booking.newsletter_optout_tokens'),to_regclass('booking.newsletter_suppressions')]loop
   if target is null then raise exception 'booking_262:259 permanent tables missing';end if;
   if has_table_privilege(role_name,target,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')then
    raise exception 'booking_262: permanent tables have unexpected direct access';end if;
  end loop;
 end loop;
 for item in select * from(values
  ('booking.newsletter_optout_tokens',array['address_fingerprint:text:true','created_at:timestamp with time zone:true','token:uuid:true']),
  ('booking.newsletter_suppressions',array['address_fingerprint:text:true','unsubscribed_at:timestamp with time zone:true'])
 )v(name,cols)loop
  target:=to_regclass(item.name);
  if not exists(select 1 from pg_catalog.pg_class where oid=target and relkind='r'and relrowsecurity)
   or exists(select 1 from pg_catalog.pg_policy where polrelid=target)then raise exception 'booking_262: private RLS table shape differs';end if;
  select array_agg(attname::text||':'||format_type(atttypid,atttypmod)||':'||attnotnull::text order by attname)into actual_cols
   from pg_catalog.pg_attribute where attrelid=target and attnum>0 and not attisdropped;
  if actual_cols is distinct from item.cols then raise exception 'booking_262: permanent column definition differs';end if;
 end loop;
 if (select count(*)from pg_catalog.pg_sequence s join pg_catalog.pg_class c on c.oid=s.seqrelid
  where s.seqrelid in(to_regclass('booking.newsletter_campaign_id_seq'),to_regclass('booking.newsletter_log_id_seq'))
  and c.relpersistence='p' and s.seqtypid='bigint'::regtype and s.seqincrement=1 and s.seqcache=1 and not s.seqcycle)<>2
  or exists(select 1 from pg_catalog.pg_depend where classid='pg_class'::regclass
   and objid in(to_regclass('booking.newsletter_campaign_id_seq'),to_regclass('booking.newsletter_log_id_seq'))and deptype in('a','i'))then
   raise exception 'booking_262: permanent unowned identity sequences differ';end if;
 foreach role_name in array array['anon','authenticated','service_role']loop
  if has_sequence_privilege(role_name,'booking.newsletter_campaign_id_seq','SELECT,USAGE,UPDATE')
   or has_sequence_privilege(role_name,'booking.newsletter_log_id_seq','SELECT,USAGE,UPDATE')then raise exception 'booking_262: identities exposed';end if;
 end loop;
 -- Compare exact259 function bodies, execution modes, empty search_path and intended grants.
 for fn in select * from(values
    ('booking._newsletter_fingerprint(text)','c83f9ac2522fa82bbe4bd03d6bc24cc9102e458454b2d075f29350c24599c693',false,'i',true),
    ('booking._newsletter_address_blocked(text,text)','fc27d440f6d37e07661f9a8c405ea0620bf6faaa375b550e69908afaed021fe3',true,'s',false),
    ('booking.public_newsletter_unsubscribe(uuid)','c053561be2b69a3f6c6648bd19330cd5ac00d0f4d21b6088386221df27823a7c',true,'v',false),
    ('booking._newsletter_capture_general_optout()','63112be9242457871279f86e9337c7b06f7d68983016fd6e1e962580eea55f8f',true,'v',false)
 )v(signature,body_sha256,definer,volatility,is_strict)loop
  if not exists(select 1 from pg_catalog.pg_proc p where p.oid=to_regprocedure(fn.signature)
   and encode(extensions.digest(convert_to(p.prosrc,'UTF8'),'sha256'),'hex')=fn.body_sha256
   and p.prosecdef=fn.definer and p.provolatile::text=fn.volatility and p.proisstrict=fn.is_strict
   and p.proconfig=array['search_path=""']::text[])then raise exception 'booking_262: exact259 permanent helper/RPC differs';end if;
  if exists(select 1 from pg_catalog.pg_proc p cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
    where p.oid=to_regprocedure(fn.signature)and a.grantee=0 and a.privilege_type='EXECUTE')then raise exception 'booking_262: unexpected PUBLIC execute';end if;
  foreach role_name in array array['anon','authenticated','service_role']loop
   if has_function_privilege(role_name,to_regprocedure(fn.signature),'EXECUTE')
     is distinct from (fn.signature='booking.public_newsletter_unsubscribe(uuid)')then raise exception 'booking_262: permanent RPC grants differ';end if;
  end loop;
 end loop;
 if not exists(select 1 from pg_catalog.pg_trigger t where t.tgrelid='booking.customers'::regclass
  and t.tgname='newsletter_capture_general_optout'and not t.tgisinternal and t.tgenabled='O'
  and t.tgtype=21 and t.tgqual is null and octet_length(t.tgargs)=0
  and t.tgfoid=to_regprocedure('booking._newsletter_capture_general_optout()')
  and (select array_agg(a.attname::text order by a.attname)from unnest(t.tgattr::smallint[])n
    join pg_catalog.pg_attribute a on a.attrelid=t.tgrelid and a.attnum=n)=array['marketing_consent','marketing_unsubscribed_at']::text[])then
  raise exception 'booking_262: exact enabled customer capture trigger missing';end if;
 if exists(select 1 from booking.customers c where c.marketing_unsubscribed_at is not null and booking._valid_email(c.email)
  and not exists(select 1 from booking.newsletter_suppressions s where s.address_fingerprint=booking._newsletter_fingerprint(c.email)))then
  raise exception 'booking_262:259 explicit opt-out backfill/capture incomplete';end if;
end $verify$;
