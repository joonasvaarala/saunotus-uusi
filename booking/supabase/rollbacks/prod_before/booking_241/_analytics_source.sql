CREATE OR REPLACE FUNCTION booking._analytics_source(p_referrer text, p_utm_source text, p_utm_campaign text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare d text := lower(coalesce(p_referrer,''));
begin
  if p_utm_source is not null or p_utm_campaign is not null then return 'campaign'; end if;
  if d ~ '^maps\.google\.[a-z.]+$' then return 'google_maps'; end if;
  if d ~ '(^|\.)(google\.[a-z.]+|bing\.com|duckduckgo\.com)$' then return 'google_search'; end if;
  if d ~ '(^|\.)(instagram\.com|facebook\.com|fb\.com|tiktok\.com|t\.co)$' then return 'social'; end if;
  if d = '' or d ~ '(^|\.)(saunotus\.(fi|com)|github\.io)$' or d = 'localhost' then return 'direct'; end if;
  return 'referral';
end $function$
;
