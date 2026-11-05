CREATE OR REPLACE FUNCTION booking.admin_pos_checkout(p_items jsonb, p_locale text DEFAULT 'fi'::text, p_email text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('pos.use');
  return booking._counter_checkout('pikakassa', p_items, p_locale, p_email, null);
end $function$
