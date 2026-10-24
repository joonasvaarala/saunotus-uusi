-- Rollback booking_134: palauttaa public_join_waitlist- ja _notify_waitlist_for_window-funktiot täsmälleen
-- booking_133-tilaan (pg_get_functiondef; funktiot ovat booking_132:n versiot) ja poistaa public_waitlist_claim-funktion.
-- Ei taulumuutoksia, ei dataa poisteta. Voidaan ajaa useasti.
set local lock_timeout = '5s';
drop function if exists booking.public_waitlist_claim(uuid);

CREATE OR REPLACE FUNCTION booking.public_join_waitlist(p_rule_id bigint, p_date date, p_persons integer DEFAULT 1, p_name text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_locale text DEFAULT 'fi'::text, p_whatsapp_opt_in boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rule booking.schedule_rules;
  v_s record;
  v_name text := btrim(coalesce(p_name,''));
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_phone text := nullif(btrim(coalesce(p_phone,'')), '');
  v_token uuid;
  v_opt boolean := coalesce(p_whatsapp_opt_in, false);
begin
  if booking._setting('waitlist_enabled', 'true'::jsonb) <> 'true'::jsonb then
    return jsonb_build_object('ok',false,'code','disabled');
  end if;
  if not booking._rate_limit('waitlist:email:' || v_email, 8, interval '10 minutes') then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if length(v_name) not between 2 and 120 then return jsonb_build_object('ok',false,'code','invalid_name'); end if;
  if length(v_email) > 200 or not booking._valid_email(v_email) then return jsonb_build_object('ok',false,'code','invalid_email'); end if;
  if v_phone is not null and (length(v_phone) > 30 or v_phone !~ '^[0-9+()\- ]{6,30}$') then
    return jsonb_build_object('ok',false,'code','invalid_phone');
  end if;
  if p_locale not in ('fi','en') or p_locale is null then return jsonb_build_object('ok',false,'code','invalid_locale'); end if;
  select * into v_rule from booking.schedule_rules where id = p_rule_id and active;
  if not found or p_date is null or p_persons is null or p_persons not between greatest(1,v_rule.min_persons) and least(50,v_rule.max_persons) then
    return jsonb_build_object('ok',false,'code','invalid_session');
  end if;
  -- Tarkistus tehdään tuoreesta saatavuudesta: sulut ja exclusive-blokit eivät ole jonotettavia.
  select * into v_s from booking._sessions(p_date,p_date,v_rule.product_id,true) s
    where s.rule_id = p_rule_id and s.session_date = p_date limit 1;
  if not found or v_s.starts_at <= now() or v_s.status <> 'full' then
    return jsonb_build_object('ok',false,'code','not_full');
  end if;
  insert into booking.waitlist_entries(product_id,rule_id,session_date,starts_at,ends_at,space_id,persons,
    customer_name,customer_email,customer_phone,locale,preferred_channel,whatsapp_opt_in)
  values (v_rule.product_id,v_rule.id,p_date,v_s.starts_at,v_s.ends_at,v_rule.space_id,p_persons,
    v_name,v_email,v_phone,p_locale,case when v_opt then 'both' else 'email' end,v_opt)
  on conflict (rule_id,session_date,(lower(customer_email))) where status in ('waiting','notified')
  do update set persons=excluded.persons, customer_name=excluded.customer_name,
    customer_phone=excluded.customer_phone,locale=excluded.locale,preferred_channel=excluded.preferred_channel,
    whatsapp_opt_in=excluded.whatsapp_opt_in,starts_at=excluded.starts_at,ends_at=excluded.ends_at,
    status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,updated_at=now()
  returning public_token into v_token;
  return jsonb_build_object('ok',true,'token',v_token,'starts_at',v_s.starts_at,'ends_at',v_s.ends_at,'persons',p_persons);
end $function$;

CREATE OR REPLACE FUNCTION booking._notify_waitlist_for_window(p_space_id bigint, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w booking.waitlist_entries;
  v_s record;
  v_site text := rtrim(coalesce(booking._setting('site_base_url') #>> '{}',''),'/');
  v_shop text;
  v_name text;
  v_dedupe text;
  v_wa boolean := booking._setting('waitlist_whatsapp_enabled','false'::jsonb) = 'true'::jsonb;
  v_h integer := extract(hour from now() at time zone 'Europe/Helsinki')::int;
  v_start integer := (booking._setting('waitlist_quiet_hours_start','21'::jsonb) #>> '{}')::int;
  v_end integer := (booking._setting('waitlist_quiet_hours_end','8'::jsonb) #>> '{}')::int;
  v_wa_after timestamptz;
  v_n integer := 0;
begin
  if booking._setting('waitlist_enabled','true'::jsonb) <> 'true'::jsonb then return 0; end if;
  if p_space_id is null or p_starts_at is null or p_ends_at is null then return 0; end if;
  for w in select * from booking.waitlist_entries
    where space_id=p_space_id and status='waiting' and starts_at>now()
      and starts_at<p_ends_at and ends_at>p_starts_at
    order by created_at,id for update skip locked
  loop
    select * into v_s from booking._sessions(w.session_date,w.session_date,w.product_id,true) s
      where s.rule_id=w.rule_id and s.session_date=w.session_date limit 1;
    if not found or v_s.starts_at<>w.starts_at or v_s.status<>'available' or v_s.remaining < w.persons then continue; end if;
    -- Kaupan polku kielen mukaan (content/site.json pages.book): fi /varaa/, en /en/book/.
    v_shop := case when w.locale='en' then '/en/book/' else '/varaa/' end;
    select coalesce(case when w.locale='en' then nullif(p.name_en,'') end,p.name)
      into v_name from kb.products p where p.id=w.product_id;
    v_dedupe := 'waitlist:'||w.id||':spot_freed:'||to_char(w.updated_at,'YYYYMMDDHH24MISSUS');
    -- Jonotuslistan sähköposti kuuluu nykyiseen send-emails -putkeen; dedupe estää kaksoislähetyksen.
    insert into booking.email_outbox(kind,locale,dedupe_key,status,payload)
    values ('waitlist_spot_freed',w.locale,v_dedupe,'pending',jsonb_build_object(
      'to_email',w.customer_email,'to_name',w.customer_name,'product_name',v_name,
      'starts_at',w.starts_at,'ends_at',w.ends_at,'persons',w.persons,
      'book_url',v_site||v_shop||'#/varaa/'||w.rule_id||'/'||w.session_date||'/'||w.product_id||'?n='||w.persons||'&wl='||w.public_token,
      'leave_url',v_site||v_shop||'?poistu_jonosta='||w.public_token))
    on conflict (dedupe_key) do nothing;
    v_wa_after := null;
    if v_wa and w.whatsapp_opt_in and w.customer_phone is not null then
      if v_start > v_end then
        if v_h >= v_start then
          v_wa_after := (((now() at time zone 'Europe/Helsinki')::date + 1)::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
        elsif v_h < v_end then
          v_wa_after := ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
        else v_wa_after := now(); end if;
      else
        v_wa_after := case when v_h >= v_start and v_h < v_end then
          ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki'
          else now() end;
      end if;
    end if;
    update booking.waitlist_entries set status='notified',notified_at=now(),
      whatsapp_send_after=v_wa_after,whatsapp_queued_at=null,updated_at=now()
    where id=w.id;
    v_n:=v_n+1;
  end loop;
  return v_n;
end $function$;

revoke all on function booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function booking.public_join_waitlist(bigint,date,integer,text,text,text,text,boolean) from public;
grant execute on function booking.public_join_waitlist(bigint,date,integer,text,text,text,text,boolean) to anon,authenticated,service_role;
