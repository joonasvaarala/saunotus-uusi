CREATE OR REPLACE FUNCTION booking._analytics_utm_ok(p_value text, p_max integer)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select p_value is null or (
    char_length(p_value) <= p_max
    and p_value ~ '^[a-z0-9][a-z0-9_.-]*$'
    and p_value !~ '[0-9]{5,}'
    and char_length(regexp_replace(p_value, '[^0-9]', '', 'g')) < 9
    and position('@' in p_value) = 0)
$function$
;
