-- Rakenne + grantit + validointi (read-only)
with f as (
  select p.proname, p.oid::regprocedure::text sig, p.pronargdefaults nd, p.pronargs na,
         has_function_privilege('anon', p.oid, 'execute') anon, has_function_privilege('authenticated', p.oid, 'execute') auth,
         p.prosecdef secdef, (select string_agg(x, ',') from unnest(p.proconfig) x) cfg
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'booking' and p.proname ~ '^_?public_(create_booking|create_booking_code|create_treatment_booking|buy_gift_card|buy_annual_card|create_training_signup)(_impl)?$')
select jsonb_build_object(
 'funcs', (select jsonb_agg(jsonb_build_object('name', proname, 'nargs', na, 'ndefaults', nd, 'anon', anon, 'auth', auth, 'secdef', secdef, 'last_arg_attr', sig like '%jsonb)' and proname not like '%_impl'))
           from f),
 'overloads_per_public_name', (select jsonb_object_agg(proname, c) from (select proname, count(*) c from f group by 1) z),
 'helpers_anon', (select jsonb_object_agg(proname, has_function_privilege('anon', p.oid, 'execute')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                   where n.nspname='booking' and proname in ('_analytics_attribution_clean','_order_attach_attribution','_analytics_orders_breakdown','_analytics_paid_orders')),
 'cols', (select jsonb_object_agg(column_name, data_type || '/' || is_nullable) from information_schema.columns where table_schema='booking' and table_name='orders' and column_name in ('analytics_session_key','attribution')),
 'clean_ok', booking._analytics_attribution_clean('{"session_key":"1b4e28ba-2d11-4a7b-8f3c-0a1b2c3d4e5f","referrer_domain":"WWW.Google.fi","utm_source":"newsletter","utm_medium":"email","utm_campaign":"syksy_2026","landing_path":"/saunavuorot/?x=1","device_type":"mobile","locale":"fi","evil":"x","email":"a@b.fi"}'),
 'clean_invalid', booking._analytics_attribution_clean('{"session_key":"not-a-uuid","referrer_domain":"a@b.fi","utm_source":"12345678901","utm_campaign":"user@example.com","landing_path":"/hallinta/x","device_type":"phone","locale":"sv"}'),
 'clean_partial', booking._analytics_attribution_clean('{"session_key":"1B4E28BA-2D11-4A7B-8F3C-0A1B2C3D4E5F","referrer_domain":"bad..domain","utm_source":"fb"}'),
 'clean_types', jsonb_build_array(booking._analytics_attribution_clean('"str"'), booking._analytics_attribution_clean('[]'), booking._analytics_attribution_clean('{}'),
                   booking._analytics_attribution_clean('{"session_key":123,"device_type":["mobile"]}'), booking._analytics_attribution_clean(null),
                   booking._analytics_attribution_clean(jsonb_build_object('referrer_domain', repeat('a', 5000) || '.fi'))),
 'attach_passthrough', jsonb_build_array(
    booking._order_attach_attribution('{"ok":false,"code":"x"}', '{"device_type":"mobile"}'),
    booking._order_attach_attribution('{"ok":true,"token":"not-uuid"}', '{"device_type":"mobile"}'),
    booking._order_attach_attribution('{"ok":true,"token":"1b4e28ba-2d11-4a7b-8f3c-0a1b2c3d4e5f"}', '"garbage"'))
) r;
