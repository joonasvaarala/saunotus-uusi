-- ================= booking_45: PDF-data, sähköpostitapahtumat, items.label_en =================
create function pg_temp.code_of(p_id bigint) returns text language sql as $$ select code from booking.gift_cards where id = p_id $$;
do $$ declare r jsonb; v_id bigint; v_tok uuid; v_oid bigint; v_ids bigint[]; v_codes text[]; cl jsonb; row_b jsonb; row_r jsonb; v_txt text; n_before int; v_mode text; begin
  perform pg_temp.as_(pg_temp.adm());
  -- items.label_en
  perform pg_temp.t_ok((select bool_and(it ? 'label_en' and it ? 'label') from booking.gift_card_packages p, jsonb_array_elements(p.items) it where p.code in ('entry_2', 'peat_mask_2', 'sauna_treatment_2', 'saunotus_2'))
     and (select count(*) from booking.gift_card_packages p, jsonb_array_elements(p.items) it where it ->> 'label_en' = 'General session') = 4 and (select items -> 1 ->> 'label_en' from booking.gift_card_packages where code = 'peat_mask_2') = 'Peat mask and foot bath'
     and (select items from booking.gift_card_packages where code = 'open') = '[]'::jsonb, 'P1 items: label + label_en kaikilla riveillä (4 pakettia), avoin ennallaan');
  perform pg_temp.t_ok(booking.public_gift_card_packages() -> 'packages' -> 3 -> 'items' -> 0 ? 'label_en', 'P2 public_gift_card_packages palauttaa items[].label_en');
  -- PDF-data
  perform pg_temp.t_ok(booking.svc_get_gift_card_pdf_data(gen_random_uuid()) ->> 'code' = 'not_found' and booking.svc_get_gift_card_pdf_data(null) ->> 'code' = 'not_found', 'P3 tuntematon/null token -> not_found');
  r := booking.admin_create_gift_card('sauna_treatment_2', null, 1, jsonb_build_object('name', 'Olli Ostaja', 'email', 'olli-ostaja@example.invalid'), 'Mikko Mallikas', 'mikko-mallikas@example.invalid', E'Hyvää syntymäpäivää!\nNauti.', 'pay_later');
  v_oid := (r ->> 'order_id')::bigint; v_id := (r -> 'cards' -> 0 ->> 'id')::bigint; v_tok := (r -> 'cards' -> 0 ->> 'public_token')::uuid;
  perform pg_temp.t_ok(booking.svc_get_gift_card_pdf_data(v_tok) ->> 'code' = 'not_ready' and booking.public_get_gift_card(v_tok) ->> 'code' = 'not_ready', 'P4 maksamaton kortti -> not_ready (svc + public)');
  perform pg_temp.t_ok((select count(*) from booking.email_outbox where kind like 'gift_card_%' and order_id = v_oid) = 0 and (select count(*) from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id) = 0, 'P5 maksamattomasta ostosta ei viestejä');
  perform booking.admin_record_payment(v_oid, 'cash', 192, null);
  r := booking.svc_get_gift_card_pdf_data(v_tok);
  perform pg_temp.t_ok((r ->> 'ok')::boolean and r ->> 'code' = booking.gift_code_fmt(pg_temp.code_of(v_id)) and r -> 'package' ->> 'name_en' is not null and r -> 'package' -> 'items' -> 1 ->> 'label_en' = 'Sauna treatment' and r ->> 'greeting' = E'Hyvää syntymäpäivää!\nNauti.'
     and r ->> 'recipient_name' = 'Mikko Mallikas' and r ->> 'buyer_name' = 'Olli Ostaja' and r -> 'seller' ->> 'logo_url' is not null and (r ->> 'redeemable_now')::boolean = false, 'P6 svc PDF-data maksetulle kortille: koodi, paketti+items, tervehdys, saaja, ostaja, myyjä+logo, redeemable_now=false (lunastus kiinni)');
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  perform pg_temp.t_ok((booking.svc_get_gift_card_pdf_data(v_tok) ->> 'redeemable_now')::boolean and booking.public_get_gift_card(v_tok) ->> 'code' = booking.gift_code_fmt(pg_temp.code_of(v_id)), 'P7 redeemable_now=true kun lunastus päällä; public_get_gift_card palauttaa saman');
  update booking.settings set value = 'false'::jsonb where key = 'gift_cards.redeem_enabled';
  -- viestit
  select count(*) into n_before from booking.email_outbox where kind = 'gift_card_buyer' and order_id = v_oid;
  perform pg_temp.t_ok(n_before = 1 and (select count(*) from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id and kind = 'gift_card_recipient' and order_id is null) = 1
     and (select status from booking.email_outbox where dedupe_key = 'gcbuyer:' || v_oid) = case when (select mode from booking.integration_config where key = 'resend') = 'off' then 'skipped' else 'pending' end,
     'P8 maksu -> 1 ostajan viesti + 1 saajan viesti (status resend-tilan mukaan)');
  perform pg_temp.t_ok((select count(*) from booking.email_outbox where kind = 'receipt' and order_id = v_oid and status = 'skipped' and last_error = 'receipt_auto_send disabled') >= 1, 'P9 kuittiviesti ohitettu (status skipped, receipt_auto_send disabled)');
  cl := booking.email_outbox_claim(50);
  select x into row_b from jsonb_array_elements(cl) x where x ->> 'kind' = 'gift_card_buyer' and (x -> 'order' ->> 'order_no')::bigint = (select order_no from booking.orders where id = v_oid);
  select x into row_r from jsonb_array_elements(cl) x where x ->> 'kind' = 'gift_card_recipient' and x ->> 'to' = 'mikko-mallikas@example.invalid';
  v_txt := coalesce(row_b::text, '') || coalesce(row_r::text, '');
  perform pg_temp.t_ok(row_b ->> 'to' = 'olli-ostaja@example.invalid' and row_b ->> 'to_name' = 'Olli Ostaja' and jsonb_array_length(row_b -> 'gift_cards') = 1 and row_b -> 'order' ->> 'order_url' is not null, 'P10 claim: ostajan rivi (to, nimi, gift_cards, tilaus + order_url)');
  perform pg_temp.t_ok(row_r ->> 'to_name' = 'Mikko Mallikas' and row_r -> 'order' = 'null'::jsonb and row_r -> 'gift_cards' -> 0 ->> 'greeting' = E'Hyvää syntymäpäivää!\nNauti.' and row_r -> 'gift_cards' -> 0 ->> 'buyer_name' = 'Olli Ostaja'
     and (row_r -> 'gift_cards' -> 0 ->> 'amount')::numeric = 192, 'P11 claim: saajan rivi (to=saaja, ei tilausta/order_url, tervehdys, ostaja, summa)');
  perform pg_temp.t_ok(position(pg_temp.code_of(v_id) in replace(v_txt, '-', '')) = 0 and v_txt not like '%"code"%', 'P12 claim ei sisällä kortin koodia');
  perform pg_temp.t_ok(position((select public_token::text from booking.gift_cards where id = v_id) in v_txt) > 0, 'P13 claim sisältää kortin public_tokenin (PDF-linkki)');
  -- idempotenssi: toinen maksu/tilapäivitys ei tuplaa
  update booking.orders set payment_status = 'paid' where id = v_oid;
  perform booking._gc_activate_order(v_oid);
  perform pg_temp.t_ok((select count(*) from booking.email_outbox where kind like 'gift_card_%' and (order_id = v_oid or dedupe_key = 'gcrecip:' || v_id)) = 2, 'P14 ei kaksoisviestejä (dedupe)');
  -- maksuton myöntö: saajan viesti vain jos saaja annettu
  r := booking.admin_create_gift_card('open', 50, 2, null, 'Saaja Kaksi', 'saaja-kaksi@example.invalid', null, null, null, null, 'en', 'hyvitys testi');
  perform pg_temp.t_ok((select count(*) from booking.email_outbox e where e.kind = 'gift_card_recipient' and e.payload ->> 'to_email' = 'saaja-kaksi@example.invalid') = 2 and (select bool_and(locale = 'en') from booking.email_outbox e where e.payload ->> 'to_email' = 'saaja-kaksi@example.invalid'), 'P15 maksuton myöntö 2 korttia + saajan sähköposti -> 2 saajaviestiä (locale en)');
  r := booking.admin_create_gift_card('open', 50, 1, null, null, null, null, null, null, null, 'fi', 'ei sahkopostia');
  perform pg_temp.t_ok(not exists (select 1 from booking.email_outbox e where e.payload -> 'card_ids' @> to_jsonb((r -> 'cards' -> 0 ->> 'id')::bigint)), 'P16 ilman saajan/ostajan sähköpostia ei viestiä');
  -- resend off -> skipped
  select mode into v_mode from booking.integration_config where key = 'resend';
  update booking.integration_config set mode = 'off' where key = 'resend';
  r := booking.admin_create_gift_card('open', 50, 1, null, 'Saaja Kolme', 'saaja-kolme@example.invalid', null, null, null, null, 'fi', 'off testi');
  perform pg_temp.t_ok((select status from booking.email_outbox where payload ->> 'to_email' = 'saaja-kolme@example.invalid') = 'skipped', 'P17 resend.mode=off -> status skipped');
  update booking.integration_config set mode = v_mode where key = 'resend';
  -- peruttu ennen maksua: ei viestejä
  r := booking.admin_create_gift_card('open', 40, 1, jsonb_build_object('name', 'Peruja', 'email', 'peruja@example.invalid'), 'Saaja Neljä', 'saaja-nelja@example.invalid', null, 'pay_later');
  update booking.orders set status = 'cancelled' where id = (r ->> 'order_id')::bigint;
  perform pg_temp.t_ok(not exists (select 1 from booking.email_outbox where payload ->> 'to_email' in ('saaja-nelja@example.invalid', 'peruja@example.invalid')), 'P18 peruttu ostotilaus -> ei viestejä');
  -- ACL
  perform pg_temp.t_ok(has_function_privilege('service_role', 'booking.svc_get_gift_card_pdf_data(uuid)', 'execute') and not has_function_privilege('anon', 'booking.svc_get_gift_card_pdf_data(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'booking.svc_get_gift_card_pdf_data(uuid)', 'execute') and has_function_privilege('anon', 'booking.public_get_gift_card(uuid)', 'execute')
     and not has_function_privilege('anon', 'booking._gc_enqueue_email(text,bigint,bigint[],text,text,text,text)', 'execute') and not has_function_privilege('authenticated', 'booking._gc_enqueue_email(text,bigint,bigint[],text,text,text,text)', 'execute')
     and has_function_privilege('service_role', 'booking.email_outbox_claim(integer)', 'execute') and not has_function_privilege('anon', 'booking.email_outbox_claim(integer)', 'execute'), 'P19 oikeudet: svc PDF-data vain service_role; public_get_gift_card anon; claim ei anonille');
end $$;
