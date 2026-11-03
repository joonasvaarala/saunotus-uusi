-- E2E DEV 2: raportti + linkitys + muut funktiot. Kaikki perutaan (raise exception lopussa).
do $t$
declare pk jsonb; it jsonb; r2 jsonb; out jsonb := '{}'; v_today date := (now() at time zone 'Europe/Helsinki')::date; s jsonb; v_uid uuid;
begin
  pk := booking.public_gift_card_packages();
  select p into it from jsonb_array_elements(pk->'packages') p order by (p->>'is_open')::boolean desc nulls last limit 1;
  it := case when coalesce((it->>'is_open')::boolean,false) then jsonb_build_array(jsonb_build_object('package', it->>'code','quantity',1,'amount',50))
             else jsonb_build_array(jsonb_build_object('package', it->>'code','quantity',1)) end;
  set local role anon;
  r2 := booking.public_buy_gift_card(p_items => it, p_name => 'Testi Ostaja', p_email => 'attr-test5@example.com', p_phone => '+358401234567',
          p_attribution => '{"session_key":"1b4e28ba-2d11-4a7b-8f3c-0a1b2c3d4e5f","utm_source":"newsletter","utm_campaign":"syksy","device_type":"tablet","locale":"fi"}');
  -- muut kääreet: virhepolut palautuvat ennallaan, sekä vanha positional että uusi nimetty kutsu resolvoituvat
  out := out || jsonb_build_object(
    'booking_old_positional', (booking.public_create_booking(-1, v_today + 3, 2, 'Testi', 'attr-test6@example.com', '+358401234567'))->'code',
    'booking_named_attr', (booking.public_create_booking(p_rule_id => -1, p_date => v_today + 3, p_persons => 2, p_name => 'Testi', p_email => 'attr-test6@example.com', p_phone => '+358401234567', p_attribution => '{"device_type":"mobile"}'))->'code',
    'code_named_attr', (booking.public_create_booking_code(p_rule_id => -1, p_date => v_today + 3, p_persons => 2, p_name => 'Testi', p_email => 'attr-test6@example.com', p_phone => '+358401234567', p_code => 'XXXX', p_attribution => '{}'))->'code',
    'treatment_named_attr', (booking.public_create_treatment_booking(p_product_id => -1, p_start => now() + interval '3 days', p_persons => 1, p_name => 'Testi', p_email => 'attr-test6@example.com', p_phone => '+358401234567', p_attribution => '{"device_type":"mobile"}'))->'code',
    'training_named_attr', (booking.public_create_training_signup(p_rule_id => -1, p_date => v_today + 3, p_name => 'Testi', p_email => 'attr-test6@example.com', p_phone => '+358401234567', p_country => 'FI', p_language => 'fi', p_locale => 'fi', p_note => null, p_marketing_consent => false, p_privacy_consent => true, p_attribution => '{"device_type":"mobile"}'))->'code',
    'annual_named_attr', (booking.public_buy_annual_card(p_name => 'Testi', p_email => 'attr-test6@example.com', p_phone => '+358401234567', p_attribution => '{"device_type":"mobile"}'))->'code');
  reset role;
  -- merkitään testitilaus maksetuksi + käyntitapahtuma samalla istunnolla -> linked
  update booking.orders set status = 'confirmed', payment_status = 'paid' where public_token = (r2->>'token')::uuid;
  insert into booking.analytics_events(session_key, event_type, path, locale, device_type, source_category, event_date)
    values ('1b4e28ba-2d11-4a7b-8f3c-0a1b2c3d4e5f', 'page_view', '/lahjakortti/', 'fi', 'tablet', 'campaign', v_today);
  out := out || jsonb_build_object('breakdown', booking._analytics_orders_breakdown(v_today, v_today),
                                   'paid', (select to_jsonb(x) from booking._analytics_paid_orders(v_today, v_today) x));
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', st.user_id, 'role', 'authenticated')::text
       from booking.staff st join booking.roles ro on ro.code = st.role and ro.active and ro.is_staff
      where st.active and exists (select 1 from booking.role_permissions rp where rp.role_code = st.role and rp.permission = 'reports.view')
      order by st.created_at limit 1), true);
  set local role authenticated;
  s := booking.admin_analytics_summary(v_today, v_today);
  reset role;
  out := out || jsonb_build_object('summary_funnel', s->'funnel', 'summary_sources', s->'sources', 'summary_devices', s->'devices_and_locales');
  raise exception 'TESTRESULT %', out;
end $t$;
