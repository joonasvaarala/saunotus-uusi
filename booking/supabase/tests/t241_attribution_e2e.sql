-- E2E DEV: luo tilauksia anon-roolissa ja PERUU kaiken (raise exception lopussa -> rollback). Ei jätä dataa.
do $t$
declare pk jsonb; code text; it jsonb; r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; out jsonb := '{}'; o record;
begin
  pk := booking.public_gift_card_packages();
  select p into it from jsonb_array_elements(pk->'packages') p order by (p->>'is_open')::boolean desc nulls last limit 1;
  if coalesce((it->>'is_open')::boolean, false) then it := jsonb_build_array(jsonb_build_object('package', it->>'code', 'quantity', 1, 'amount', 50));
  else it := jsonb_build_array(jsonb_build_object('package', it->>'code', 'quantity', 1)); end if;
  out := out || jsonb_build_object('sale_enabled', pk->'sale_enabled', 'pkg_count', jsonb_array_length(coalesce(pk->'packages','[]')));
  set local role anon;
  -- 1) vanha kutsu ilman p_attribution (positional, kuten ennen)
  r1 := booking.public_buy_gift_card(it, 'Testi Ostaja', 'attr-test1@example.com', '+358401234567', false, 'fi');
  -- 2) nimetty kutsu p_attributionilla (kuten PostgREST)
  r2 := booking.public_buy_gift_card(p_items => it, p_name => 'Testi Ostaja', p_email => 'attr-test2@example.com', p_phone => '+358401234567',
          p_locale => 'en', p_attribution => '{"session_key":"1b4e28ba-2d11-4a7b-8f3c-0a1b2c3d4e5f","referrer_domain":"l.instagram.com","landing_path":"/en/gift-card/","device_type":"mobile","locale":"en","junk":1}');
  -- 3) roskadata ei kaada tilausta
  r3 := booking.public_buy_gift_card(p_items => it, p_name => 'Testi Ostaja', p_email => 'attr-test3@example.com', p_phone => '+358401234567',
          p_attribution => '{"session_key":"<script>","utm_source":"a@b.fi","device_type":42}');
  r4 := booking.public_buy_gift_card(p_items => it, p_name => 'Testi Ostaja', p_email => 'attr-test4@example.com', p_phone => '+358401234567',
          p_attribution => '"not an object"');
  reset role;
  out := out || jsonb_build_object('r1_ok', r1->'ok', 'r1_code', r1->'code', 'r2_ok', r2->'ok', 'r2_code', r2->'code', 'r3_ok', r3->'ok', 'r4_ok', r4->'ok',
          'r_keys_same', (select array_agg(k order by k) from jsonb_object_keys(r1) k) = (select array_agg(k order by k) from jsonb_object_keys(r2) k));
  for o in select x.n, ord.analytics_session_key::text sk, ord.attribution from (values (1, r1), (2, r2), (3, r3), (4, r4)) x(n, r)
             left join booking.orders ord on ord.public_token = nullif(x.r->>'token','')::uuid loop
    out := out || jsonb_build_object('o' || o.n, jsonb_build_object('sk', o.sk, 'attr', o.attribution));
  end loop;
  -- uusinta ei ylikirjoita (idempotentti)
  perform booking._order_attach_attribution(r2, '{"device_type":"desktop"}');
  out := out || jsonb_build_object('o2_after_retry', (select attribution->>'device_type' from booking.orders where public_token = (r2->>'token')::uuid));
  raise exception 'TESTRESULT %', out;
end $t$;
