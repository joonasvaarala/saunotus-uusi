CREATE OR REPLACE FUNCTION booking.public_track_event(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_type text; v_sk text; v_path text; v_locale text; v_dev text; v_domain text; v_us text; v_um text; v_uc text; v_source text; v_slug text;
  v_pid bigint; v_token uuid; v_order bigint; v_gross numeric(10,2); v_status text;
  v_key text; v_ip text; v_today date := (now() at time zone 'Europe/Helsinki')::date; v_lim integer; v_cap integer; v_n integer;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or octet_length(p_payload::text) > 4096 then return '{"ok":false,"code":"invalid_payload"}'::jsonb; end if;
  -- booking_150: IP-kohtainen raja (_rate_limit kirjaa myös estetyt). IP vain tiivisteenä ämpärin nimessä, ei tapahtumatauluun.
  v_ip := booking._client_ip();
  begin
    if v_ip is not null then
      v_lim := (booking._setting('analytics_rl_ip_per_10min', '120'::jsonb) #>> '{}')::integer;
    else
      v_lim := (booking._setting('analytics_rl_noip_per_10min', '60'::jsonb) #>> '{}')::integer;
    end if;
  exception when others then v_lim := case when v_ip is not null then 120 else 60 end;
  end;
  if not booking._rate_limit(case when v_ip is not null then 'analytics:ip:' || md5(v_today::text || ':' || v_ip) else 'analytics:noip' end,
                             coalesce(v_lim, 60), interval '10 minutes') then
    return '{"ok":false,"code":"rate_limited"}'::jsonb;
  end if;
  -- Älä hyväksy ylimääräisiä henkilötietoja / HTTP-tunnisteita. source_category sallitaan vanhan skriptin vuoksi, mutta sitä ei käytetä.
  for v_key in select jsonb_object_keys(p_payload) loop
    if v_key not in ('session_key','event_type','path','locale','device_type','referrer_domain','utm_source','utm_medium','utm_campaign','source_category','product_id','product_slug','order_token','bot') then
      return '{"ok":false,"code":"invalid_field"}'::jsonb;
    end if;
  end loop;
  if p_payload->>'bot' = 'true' then return '{"ok":false,"code":"bot"}'::jsonb; end if;
  -- Pyyntöotsaketta käytetään vain hetkelliseen suodatukseen: sitä ei tallenneta.
  if coalesce((nullif(current_setting('request.headers',true),'')::jsonb)->>'user-agent','') ~* '(bot|crawler|spider|headless|lighthouse|playwright|puppeteer|selenium)' then
    return '{"ok":false,"code":"bot"}'::jsonb;
  end if;
  v_type := p_payload->>'event_type'; v_sk := lower(coalesce(p_payload->>'session_key',''));
  if v_type is null or v_type not in ('page_view','product_view','checkout_start','purchase')
     or v_sk !~ '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'
  then return '{"ok":false,"code":"invalid_event"}'::jsonb; end if;
  -- booking_150: polku tunnettuihin sivupolkuihin (query/fragment pois, tuntematon -> '/muu').
  v_path := booking._analytics_path(p_payload->>'path');
  if v_path is null then return '{"ok":false,"code":"invalid_path"}'::jsonb; end if;
  v_locale := coalesce(p_payload->>'locale','fi'); v_dev := coalesce(p_payload->>'device_type','desktop');
  if v_locale not in ('fi','en') or v_dev not in ('mobile','desktop','tablet') then return '{"ok":false,"code":"invalid_device_or_locale"}'::jsonb; end if;
  v_domain := lower(nullif(left(coalesce(p_payload->>'referrer_domain',''), 180),''));
  if v_domain is not null and (v_domain !~ '^[a-z0-9.-]+$' or not (v_domain like '%.%') or v_domain like '%..%' or v_domain like '.%' or v_domain like '%.' or v_domain like '%@%') then
    return '{"ok":false,"code":"invalid_referrer"}'::jsonb;
  end if;
  -- booking_150: UTM-arvot tiukemmin (pituus, merkit, ei numerojonoja eikä sähköposteja). Ei katkaista: liian pitkä hylätään.
  v_us := nullif(lower(coalesce(p_payload->>'utm_source','')), '');
  v_um := nullif(lower(coalesce(p_payload->>'utm_medium','')), '');
  v_uc := nullif(lower(coalesce(p_payload->>'utm_campaign','')), '');
  if not booking._analytics_utm_ok(v_us, 40) or not booking._analytics_utm_ok(v_um, 40) or not booking._analytics_utm_ok(v_uc, 60) then
    return '{"ok":false,"code":"invalid_utm"}'::jsonb;
  end if;
  v_slug := nullif(left(coalesce(p_payload->>'product_slug',''), 100),'');
  if v_slug is not null and v_slug !~ '^[a-z0-9-]+$' then return '{"ok":false,"code":"invalid_slug"}'::jsonb; end if;
  if p_payload ? 'product_id' and p_payload->>'product_id' ~ '^[0-9]{1,12}$' then v_pid := (p_payload->>'product_id')::bigint; end if;
  if v_pid is not null and not exists(select 1 from kb.products where id=v_pid) then v_pid := null; end if;
  -- Älä tallenna mielivaltaisia merkkijonoja tuoteniminä. Tuote hyväksytään vain katalogista.
  if v_pid is null and v_slug is not null then select p.id into v_pid from kb.products p where p.slug=v_slug order by p.id limit 1; end if;
  if v_pid is null and v_path in ('/lahjakortti/','/en/gift-card/') then
    select p.id into v_pid from kb.products p where p.slug='lahjakortti' order by p.id limit 1;
  end if;
  if v_pid is not null then select p.slug into v_slug from kb.products p where p.id=v_pid;
  else v_slug := null; end if;
  -- booking_150: lähde aina palvelimella referreristä ja UTM-arvoista (asiakkaan source_category ohitetaan).
  v_source := booking._analytics_source(v_domain, v_us, v_uc);
  if v_type <> 'purchase' and (select count(*) from booking.analytics_events where session_key=v_sk and event_date=v_today) >= 200 then
    return '{"ok":false,"code":"too_many_events"}'::jsonb;
  end if;
  if v_type = 'purchase' then
    begin v_token := (p_payload->>'order_token')::uuid; exception when invalid_text_representation then return '{"ok":false,"code":"invalid_order"}'::jsonb; end;
    if v_token is null then return '{"ok":false,"code":"invalid_order"}'::jsonb; end if;
    select o.id,o.total_gross,o.payment_status into v_order,v_gross,v_status from booking.orders o where o.public_token=v_token;
    if v_order is null or v_status <> 'paid' then return '{"ok":false,"code":"not_paid"}'::jsonb; end if;
    -- Oikea tuote päätellään tilausrivistä; selain ei saa määrätä ostosummaa eikä tuotetta.
    select oi.product_id, p.slug into v_pid,v_slug from booking.order_items oi
      left join kb.products p on p.id=oi.product_id
      where oi.order_id=v_order and oi.product_id is not null
      order by oi.id limit 1;
  else
    -- booking_150: globaali päiväkatto. Ylitys ohitetaan hiljaa (sama vastaus kuin tallennuksessa, ei paljasta tilaa).
    begin
      v_cap := (booking._setting('analytics_daily_cap', '20000'::jsonb) #>> '{}')::integer;
    exception when others then v_cap := 20000;
    end;
    insert into booking.analytics_daily_counts as c(event_date, n) values (v_today, 1)
      on conflict (event_date) do update set n = c.n + 1
      returning c.n into v_n;
    if v_n > coalesce(v_cap, 20000) then return '{"ok":true}'::jsonb; end if;
  end if;
  insert into booking.analytics_events(session_key,event_type,path,locale,device_type,source_category,referrer_domain,utm_source,utm_medium,utm_campaign,product_id,product_slug,order_id,amount_gross)
  values(v_sk,v_type,v_path,v_locale,v_dev,v_source,v_domain,v_us,v_um,v_uc,v_pid,v_slug,v_order,v_gross)
  on conflict do nothing;
  return '{"ok":true}'::jsonb;
end $function$
;
