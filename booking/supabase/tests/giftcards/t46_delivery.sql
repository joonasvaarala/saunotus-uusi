-- ================= booking_46: toimitusvalinta, saateteksti, ajastus =================
create function pg_temp.code_of(p_id bigint) returns text language sql as $$ select code from booking.gift_cards where id = p_id $$;
create function pg_temp.cid(p_tok uuid) returns bigint language sql as $$ select id from booking.gift_cards where public_token = p_tok $$;
create function pg_temp.today() returns date language sql as $$ select booking._gc_today() $$;
do $$ declare r jsonb; v_id bigint; v_oid bigint; cl jsonb; rb jsonb; rr jsonb; v_cover text; n int; v_ids bigint[]; v_tok uuid; v_ob bigint; v_rid bigint; v_ts timestamptz; v_m text; v_ok boolean; v_d date := booking._gc_today(); begin
  perform pg_temp.as_(pg_temp.adm());
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.sale_enabled';
  -- U1 skeema + vanhat rivit
  perform pg_temp.t_ok((select count(*) from booking.gift_cards where cover_message is null and deliver_on is null and delivered_at is null and delivery_to = case when source = 'native' and recipient_email is not null then 'recipient' else 'buyer' end) = (select count(*) from booking.gift_cards) and not exists (select 1 from booking.gift_cards where source = 'johku' and delivery_to <> 'buyer')
     and (select count(*) from information_schema.columns where table_schema = 'booking' and table_name = 'gift_cards' and column_name in ('delivery_to', 'cover_message', 'deliver_on', 'deliver_time', 'delivered_at')) = 5, 'U1 sarakkeet olemassa; vanhat kortit: Johku=buyer, natiivi+saajan sähköposti=recipient, ei ajastusta');
  perform pg_temp.t_ok((select valid_months from booking.gift_card_packages where code = 'open') = 6 and (select bool_and(valid_months = 6) from booking.gift_card_packages) and (select column_default from information_schema.columns where table_schema = 'booking' and table_name = 'gift_cards' and column_name = 'valid_months') = '6', 'U2 kaikkien pakettien voimassaolo 6 kk (sarakeoletus 6)');
  -- U3 maksuton myöntö: buyer-toimitus -> vain ostajan viesti
  r := booking.admin_create_gift_card('open', 50, 1, jsonb_build_object('name', 'Olli Ostaja', 'email', 'olli-ostaja@example.invalid'), 'Mikko M', 'mikko@example.invalid', 'Terve', null, null, null, 'fi', 'testi buyer', 'admin', 'buyer', 'EI NÄKYVIIN', (v_d + 5)::text, '10:00');
  v_id := (r -> 'cards' -> 0 ->> 'id')::bigint;
  perform pg_temp.t_ok(r -> 'cards' -> 0 ->> 'delivery_to' = 'buyer' and r -> 'cards' -> 0 -> 'cover_message' = 'null'::jsonb and r -> 'cards' -> 0 -> 'deliver_on' = 'null'::jsonb
     and (select count(*) from booking.email_outbox where kind = 'gift_card_buyer' and payload -> 'card_ids' @> to_jsonb(v_id)) = 1 and (select count(*) from booking.email_outbox where kind = 'gift_card_recipient' and payload -> 'card_ids' @> to_jsonb(v_id)) = 0,
     'U3 delivery_to=buyer: saate/ajastus ohitetaan (null), vain ostajan viesti, ei saajan viestiä vaikka saajan sähköposti annettu');
  -- U4 oletus: saajan sähköposti annettu, delivery_to null -> recipient, heti
  r := booking.admin_create_gift_card('open', 50, 1, jsonb_build_object('name', 'Olli Ostaja', 'email', 'olli-ostaja@example.invalid'), 'Mikko M', 'mikko@example.invalid', 'Terve', null, null, null, 'fi', 'testi default');
  v_id := (r -> 'cards' -> 0 ->> 'id')::bigint;
  perform pg_temp.t_ok(r -> 'cards' -> 0 ->> 'delivery_to' = 'recipient' and (select next_attempt_at from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id) <= now() + interval '5 seconds', 'U4 oletus: saajan sähköposti -> delivery_to=recipient, saajan viesti heti (next_attempt_at ~ nyt)');
  -- virheet
  perform pg_temp.t_err($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', null, null, null, null, null, 'fi', 'testi', 'admin', 'recipient')$q$, 'recipient_email_required', 'U5 recipient ilman sähköpostia');
  perform pg_temp.t_err($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'postitse')$q$, 'invalid_delivery_to', 'U6 tuntematon delivery_to');
  perform pg_temp.t_err(format($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', %L)$q$, repeat('x', 1001)), 'invalid_cover_message', 'U7 saateteksti 1001 merkkiä');
  perform pg_temp.t_err(format($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', null, %L)$q$, (v_d - 1)::text), 'deliver_on_past', 'U8 eilinen päivä -> deliver_on_past');
  perform pg_temp.t_err(format($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', null, %L, %L)$q$, v_d::text, to_char((now() at time zone 'Europe/Helsinki') - interval '2 hours', 'HH24:MI')), 'deliver_on_past', 'U9 tänään menneellä kellonajalla -> deliver_on_past')
    ;
  perform pg_temp.t_err(format($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', null, %L)$q$, (v_d + interval '6 months' + interval '1 day')::date::text), 'deliver_on_too_far', 'U10 yli 6 kk (kortin voimassaolo) -> deliver_on_too_far');
  perform pg_temp.t_err(format($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, 36, 'fi', 'testi', 'admin', 'recipient', null, %L)$q$, (v_d + interval '12 months' + interval '1 day')::date::text), 'deliver_on_too_far', 'U11 yli 12 kk (vaikka voimassaolo 36 kk) -> deliver_on_too_far');
  perform pg_temp.t_err($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', null, '31.12.2026')$q$, 'invalid_deliver_on', 'U12 virheellinen päivämäärämuoto');
  perform pg_temp.t_err($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', null, '2027-02-31')$q$, 'invalid_deliver_on', 'U13 mahdoton päivämäärä');
  perform pg_temp.t_err(format($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', null, %L, '25:00')$q$, (v_d + 3)::text), 'invalid_deliver_time', 'U14 virheellinen kellonaika');
  perform pg_temp.t_err($q$select booking.admin_create_gift_card('open', 50, 1, null, 'M', 'm@example.invalid', null, null, null, null, 'fi', 'testi', 'admin', 'recipient', null, null, '10:00')$q$, 'invalid_deliver_on', 'U15 kellonaika ilman päivää');
  -- U16 ajastus: päivä + kellonaika (Helsinki), raja-arvot sallittu
  r := booking.admin_create_gift_card('open', 50, 1, null, 'Mikko M', 'mikko@example.invalid', null, null, null, null, 'fi', 'testi ajastus', 'admin', 'recipient', E'Hei!\nTässä saate\u0007.', (v_d + 3)::text, '14:30');
  v_id := (r -> 'cards' -> 0 ->> 'id')::bigint;
  select next_attempt_at into v_ts from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id;
  perform pg_temp.t_ok((v_ts at time zone 'Europe/Helsinki') = ((v_d + 3)::text || ' 14:30')::timestamp and (select cover_message from booking.gift_cards where id = v_id) = E'Hei!\nTässä saate.' and (select deliver_time from booking.gift_cards where id = v_id) = '14:30'::time,
     'U16 ajastettu: next_attempt_at = valittu päivä klo 14:30 Helsingin aikaa; saate tallessa, ohjausmerkit poistettu, rivinvaihto säilyy');
  r := booking.admin_create_gift_card('open', 50, 1, null, 'Mikko M', 'mikko@example.invalid', null, null, null, null, 'fi', 'testi pelkkä pvm', 'admin', 'recipient', null, (v_d + 10)::text);
  v_id := (r -> 'cards' -> 0 ->> 'id')::bigint;
  select next_attempt_at into v_ts from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id;
  perform pg_temp.t_ok((v_ts at time zone 'Europe/Helsinki') = ((v_d + 10)::text || ' 09:00')::timestamp, 'U17 pelkkä päivä -> klo 09:00 Helsingin aikaa');
  r := booking.admin_create_gift_card('open', 50, 1, null, 'Mikko M', 'mikko@example.invalid', null, null, null, null, 'fi', 'testi iso', 'admin', 'recipient', repeat('ä', 1000), ((v_d + 4)::text || 'T08:15'));
  v_id := (r -> 'cards' -> 0 ->> 'id')::bigint;
  select next_attempt_at into v_ts from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id;
  perform pg_temp.t_ok(char_length((select cover_message from booking.gift_cards where id = v_id)) = 1000 and (v_ts at time zone 'Europe/Helsinki') = ((v_d + 4)::text || ' 08:15')::timestamp, 'U18 saate 1000 merkkiä OK; ISO-muoto VVVV-KK-PPTHH:MM hyväksytään');
  r := booking.admin_create_gift_card('open', 50, 1, null, 'Mikko M', 'mikko@example.invalid', null, null, null, null, 'fi', 'testi raja', 'admin', 'recipient', null, (v_d + interval '6 months')::date::text);
  perform pg_temp.t_ok(r ->> 'ok' = 'true', 'U19 täsmälleen 6 kk päässä sallittu');
  r := booking.admin_create_gift_card('open', 50, 1, null, 'Mikko M', 'mikko@example.invalid', null, null, null, null, 'fi', 'testi tanaan', 'admin', 'recipient', null, v_d::text);
  v_id := (r -> 'cards' -> 0 ->> 'id')::bigint;
  perform pg_temp.t_ok((select deliver_on from booking.gift_cards where id = v_id) is null and (select next_attempt_at from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id) <= now() + interval '5 seconds', 'U20 tänään ilman kellonaikaa = heti (deliver_on null)');
  -- U21 verkko-osto: ajastettu saajalle, maksu -> ostaja heti, saaja ajastettuna
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  r := booking.public_buy_gift_card('[{"package":"sauna_treatment_2"}]'::jsonb, 'Olli Ostaja', 'olli-ostaja@example.invalid', '+358401234567', false, 'fi', 'Mikko Mallikas', 'mikko-mallikas@example.invalid', 'Hyvää synttäriä!', 'recipient', E'Hei Mikko,\nTässä lahja!', (v_d + 10)::text, '12:00');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r -> 'cards' -> 0 ->> 'delivery_to' = 'recipient' and r -> 'cards' -> 0 ->> 'deliver_on' = (v_d + 10)::text, 'U21 public_buy: delivery_to/deliver_on palautuu cards[]:ssa');
  v_tok := (r -> 'cards' -> 0 ->> 'public_token')::uuid; v_id := pg_temp.cid(v_tok);
  select id into v_oid from booking.orders where order_no = (r ->> 'order_no')::bigint;
  perform pg_temp.t_ok(not exists (select 1 from booking.email_outbox where kind like 'gift_card_%' and (order_id = v_oid or payload -> 'card_ids' @> to_jsonb(v_id))), 'U22 maksamaton ostos: ei viestejä');
  perform pg_temp.t_ok(booking.public_get_order_gift_cards((r ->> 'token')::uuid) -> 'cards' -> 0 ->> 'delivery_to' = 'recipient' and booking.public_get_order_gift_cards((r ->> 'token')::uuid) -> 'cards' -> 0 ->> 'deliver_time' = '12:00', 'U23 public_get_order_gift_cards palauttaa delivery_to, deliver_on, deliver_time, delivered_at');
  perform pg_temp.as_(pg_temp.adm());
  perform booking.admin_record_payment(v_oid, 'cash', 192, null);
  select next_attempt_at into v_ts from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id;
  perform pg_temp.t_ok((select status from booking.email_outbox where dedupe_key = 'gcbuyer:' || v_oid) in ('pending', 'skipped') and (select next_attempt_at from booking.email_outbox where dedupe_key = 'gcbuyer:' || v_oid) <= now() + interval '5 seconds'
     and (v_ts at time zone 'Europe/Helsinki') = ((v_d + 10)::text || ' 12:00')::timestamp, 'U24 maksu: ostajan vahvistus heti, saajan viesti ajastettu valittuun hetkeen');
  cl := booking.email_outbox_claim(50);
  select x into rb from jsonb_array_elements(cl) x where x ->> 'kind' = 'gift_card_buyer' and (x -> 'order' ->> 'order_no')::bigint = (select order_no from booking.orders where id = v_oid);
  select x into rr from jsonb_array_elements(cl) x where x ->> 'kind' = 'gift_card_recipient' and x ->> 'to' = 'mikko-mallikas@example.invalid';
  perform pg_temp.t_ok(rr is null, 'U25 ajastettua saajan viestiä ei claimata ennen aikaa (next_attempt_at tulevaisuudessa)');
  perform pg_temp.t_ok(rb is not null and rb -> 'gift_cards' -> 0 ->> 'delivery_to' = 'recipient' and rb -> 'gift_cards' -> 0 ->> 'deliver_at' is not null and rb -> 'gift_cards' -> 0 ->> 'deliver_time' = '12:00'
     and rb -> 'gift_cards' -> 0 ->> 'recipient_email' = 'mikko-mallikas@example.invalid' and rb -> 'gift_cards' -> 0 -> 'cover_message' = 'null'::jsonb and rb::text not like '%Tässä lahja%', 'U26 ostajan viesti: toimitustapa, ajastettu aika, saajan osoite; saateteksti EI ostajan viestissä');
  update booking.email_outbox set status = 'pending', locked_at = null, next_attempt_at = now() where dedupe_key = 'gcrecip:' || v_id;
  cl := booking.email_outbox_claim(50);
  select x into rr from jsonb_array_elements(cl) x where x ->> 'kind' = 'gift_card_recipient' and x ->> 'to' = 'mikko-mallikas@example.invalid';
  perform pg_temp.t_ok(rr is not null and rr -> 'gift_cards' -> 0 ->> 'cover_message' = E'Hei Mikko,\nTässä lahja!' and rr -> 'order' = 'null'::jsonb and rr -> 'gift_cards' -> 0 ->> 'buyer_name' = 'Olli Ostaja', 'U27 erääntynyt saajan viesti: saateteksti + ostajan nimi mukana, ei tilausta');
  perform pg_temp.t_ok(position(pg_temp.code_of(v_id) in replace(coalesce(rr::text, '') || coalesce(rb::text, ''), '-', '')) = 0, 'U28 claim ei sisällä koodia');
  -- U29 delivered_at: dry_run ei aseta, sent asettaa (vain oikean toimitustavan kortit)
  select id into v_rid from booking.email_outbox where dedupe_key = 'gcrecip:' || v_id;
  perform booking.email_outbox_mark(v_rid, 'dry_run', null, 'dry_run');
  perform pg_temp.t_ok((select delivered_at from booking.gift_cards where id = v_id) is null, 'U29a dry_run ei merkitse delivered_at');
  perform booking.email_outbox_mark((select id from booking.email_outbox where dedupe_key = 'gcbuyer:' || v_oid), 'sent', 'x', null);
  perform pg_temp.t_ok((select delivered_at from booking.gift_cards where id = v_id) is null, 'U29b ostajan viestin sent ei merkitse saajalle toimitettavaa korttia toimitetuksi');
  perform booking.email_outbox_mark(v_rid, 'sent', 'x', null);
  perform pg_temp.t_ok((select delivered_at from booking.gift_cards where id = v_id) is not null, 'U29c saajan viestin sent -> delivered_at');
  -- U30 PDF-data ei sisällä saatetekstiä
  r := booking.svc_get_gift_card_pdf_data(v_tok);
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and not (r ? 'cover_message') and r::text not like '%Tässä lahja%' and (r ->> 'greeting') = 'Hyvää synttäriä!' and booking.public_get_gift_card(v_tok)::text not like '%Tässä lahja%', 'U30 PDF-data (svc + public_get_gift_card) ei sisällä saatetekstiä; kortin tervehdys sisältää');
  -- U31 verkko-osto buyer: saate/ajastus ohitetaan, ostajan viesti PDF-linkeillä
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  r := booking.public_buy_gift_card('[{"package":"open","amount":50}]'::jsonb, 'Olli Ostaja', 'olli-ostaja@example.invalid', '+358401234567', false, 'fi', 'Mikko Mallikas', 'mikko-mallikas@example.invalid', null, 'buyer', 'Ei näy', (v_d + 10)::text);
  v_tok := (r -> 'cards' -> 0 ->> 'public_token')::uuid; v_id := pg_temp.cid(v_tok); select id into v_ob from booking.orders where order_no = (r ->> 'order_no')::bigint;
  perform pg_temp.as_(pg_temp.adm()); perform booking.admin_record_payment(v_ob, 'cash', 50, null);
  perform pg_temp.t_ok((select cover_message is null and deliver_on is null and delivery_to = 'buyer' from booking.gift_cards where id = v_id) and not exists (select 1 from booking.email_outbox where kind = 'gift_card_recipient' and payload -> 'card_ids' @> to_jsonb(v_id))
     and (select count(*) from booking.email_outbox where dedupe_key = 'gcbuyer:' || v_ob) = 1, 'U31 delivery_to=buyer (verkko): saate/ajastus ohitetaan, vain ostajan viesti');
  perform booking.email_outbox_mark((select id from booking.email_outbox where dedupe_key = 'gcbuyer:' || v_ob), 'sent', 'x', null);
  perform pg_temp.t_ok((select delivered_at from booking.gift_cards where id = v_id) is not null, 'U32 ostajalle toimitettu kortti: ostajan viestin sent -> delivered_at');
  -- U33 verkko-osto: virheet palautuvat {ok:false, code}
  perform pg_temp.as_(''); delete from booking.rate_limit_hits;
  perform pg_temp.t_ok(booking.public_buy_gift_card('[{"package":"open","amount":50}]'::jsonb, 'O Ostaja', 'olli-ostaja@example.invalid', '+358401234567', false, 'fi', 'M', null, null, 'recipient') ->> 'code' = 'recipient_email_required', 'U33a verkko: recipient ilman saajan sähköpostia -> recipient_email_required');
  delete from booking.rate_limit_hits;
  perform pg_temp.t_ok(booking.public_buy_gift_card('[{"package":"open","amount":50}]'::jsonb, 'O Ostaja', 'olli-ostaja@example.invalid', '+358401234567', false, 'fi', 'M', 'm@example.invalid', null, 'recipient', null, (v_d - 2)::text) ->> 'code' = 'deliver_on_past', 'U33b verkko: menneisyys -> deliver_on_past');
  delete from booking.rate_limit_hits;
  perform pg_temp.t_ok(booking.public_buy_gift_card('[{"package":"open","amount":50}]'::jsonb, 'O Ostaja', 'olli-ostaja@example.invalid', '+358401234567', false, 'fi', 'M', 'm@example.invalid', null, 'recipient', null, (v_d + 200)::text) ->> 'code' = 'deliver_on_too_far', 'U33c verkko: liian kaukana -> deliver_on_too_far');
  delete from booking.rate_limit_hits;
  perform pg_temp.t_ok(booking.public_buy_gift_card('[{"package":"open","amount":50}]'::jsonb, 'O Ostaja', 'olli-ostaja@example.invalid', '+358401234567', false, 'fi', 'M', 'm@example.invalid', null, 'recipient', repeat('x', 1001)) ->> 'code' = 'invalid_cover_message', 'U33d verkko: saate liian pitkä');
  delete from booking.rate_limit_hits;
  perform pg_temp.t_ok(booking.public_buy_gift_card('[{"package":"open","amount":50}]'::jsonb, 'O Ostaja', 'olli-ostaja@example.invalid', '+358401234567', false, 'fi', 'M', 'm@example.invalid', null, 'lahetti') ->> 'code' = 'invalid_delivery_to', 'U33e verkko: virheellinen delivery_to');
  perform pg_temp.t_ok(not exists (select 1 from booking.orders o where o.customer_id in (select id from booking.customers where email = 'olli-ostaja@example.invalid') and o.id > v_ob), 'U33f virheelliset ostot eivät jätä tilauksia (rollback)');
  -- U34 rivikohtainen ohitus + vanha kutsutapa (ilman uusia parametreja)
  delete from booking.rate_limit_hits;
  r := booking.public_buy_gift_card('[{"package":"open","amount":50,"delivery_to":"recipient","recipient_email":"rivi@example.invalid","cover_message":"Rivin saate"},{"package":"entry_2"}]'::jsonb, 'Olli Ostaja', 'olli-ostaja@example.invalid', '+358401234567');
  perform pg_temp.t_ok(r ->> 'ok' = 'true' and r -> 'cards' -> 0 ->> 'delivery_to' = 'recipient' and r -> 'cards' -> 1 ->> 'delivery_to' = 'buyer', 'U34 rivikohtainen delivery_to/saate/sähköposti; oletus buyer kun saajaa ei ole; vanha 3-parametrinen kutsu toimii');
  select id into v_ob from booking.orders where order_no = (r ->> 'order_no')::bigint; perform pg_temp.as_(pg_temp.adm()); perform booking.admin_record_payment(v_ob, 'cash', (r ->> 'total')::numeric, null);
  perform pg_temp.t_ok((select count(*) from booking.email_outbox where dedupe_key = 'gcbuyer:' || v_ob) = 1 and (select count(*) from booking.email_outbox where kind = 'gift_card_recipient' and payload ->> 'to_email' = 'rivi@example.invalid') = 1, 'U35 sekatilaus: yksi ostajan viesti (kaikki kortit) + yksi saajan viesti');
  -- U36 admin myynti (pay_later) + ajastus + validointi
  perform pg_temp.as_(pg_temp.adm());
  r := booking.admin_create_gift_card('entry_2', null, 2, jsonb_build_object('name', 'Olli Ostaja', 'email', 'olli-ostaja@example.invalid'), 'Mikko M', 'mikko@example.invalid', null, 'pay_later', null, null, 'fi', null, 'admin', 'recipient', 'Admin-saate', (v_d + 2)::text);
  v_oid := (r ->> 'order_id')::bigint;
  perform pg_temp.t_ok((select count(*) from booking.gift_cards where purchase_order_id = v_oid and delivery_to = 'recipient' and cover_message = 'Admin-saate' and deliver_on = v_d + 2) = 2, 'U36 admin myynti pay_later: delivery-kentät kaikille korteille');
  perform pg_temp.t_err($q$select booking.admin_create_gift_card('entry_2', null, 1, null, null, null, null, 'pay_later', null, null, 'fi', null, 'admin', 'recipient')$q$, 'recipient_email_required', 'U37 admin myynti: recipient ilman sähköpostia -> recipient_email_required');
  -- U38 peruttu/mitätöity ennen lähetystä näkyy claimissa statuksena (send-emails ohittaa)
  update booking.gift_cards set status = 'cancelled' where id = (select id from booking.gift_cards where purchase_order_id = v_ob and delivery_to = 'recipient' limit 1);
  update booking.email_outbox set status = 'pending', next_attempt_at = now(), locked_at = null where kind = 'gift_card_recipient' and payload ->> 'to_email' = 'rivi@example.invalid';
  cl := booking.email_outbox_claim(50);
  perform pg_temp.t_ok((select x -> 'gift_cards' -> 0 ->> 'status' from jsonb_array_elements(cl) x where x ->> 'kind' = 'gift_card_recipient' and x ->> 'to' = 'rivi@example.invalid') = 'cancelled', 'U38 mitätöity kortti: claim palauttaa status=cancelled (send-emails ohittaa)');
  -- U39 tarkistusrajoitteet suoraan
  v_ok := false;
  begin update booking.gift_cards set delivery_to = 'recipient', recipient_email = null where id = v_id; exception when check_violation then v_ok := true; end;
  perform pg_temp.t_ok(v_ok, 'U39 CHECK: delivery_to=recipient vaatii recipient_email');
  v_ok := false;
  begin update booking.gift_cards set cover_message = 'x' where id = v_id and delivery_to = 'buyer'; exception when check_violation then v_ok := true; end;
  perform pg_temp.t_ok(v_ok, 'U40 CHECK: cover_message vain delivery_to=recipient');
  -- U41 oikeudet
  perform pg_temp.t_ok(has_function_privilege('anon', 'booking.public_buy_gift_card(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text)', 'execute') and has_function_privilege('authenticated', 'booking.admin_create_gift_card(text,numeric,integer,jsonb,text,text,text,text,text,integer,text,text,text,text,text,text,text)', 'execute')
     and not has_function_privilege('anon', 'booking.admin_create_gift_card(text,numeric,integer,jsonb,text,text,text,text,text,integer,text,text,text,text,text,text,text)', 'execute') and not has_function_privilege('anon', 'booking._gc_sell(jsonb,bigint,text,text,text,text,text,text,integer,text,text,text,text,text,text,text)', 'execute')
     and not has_function_privilege('anon', 'booking._gc_delivery_resolve(text,text,text,text,text,integer)', 'execute') and not has_function_privilege('authenticated', 'booking._gc_enqueue_email(text,bigint,bigint[],text,text,text,text,timestamptz)', 'execute')
     and (select count(*) from pg_proc where pronamespace = 'booking'::regnamespace and proname in ('public_buy_gift_card', 'admin_create_gift_card', '_gc_sell', '_gc_create_card', '_gc_enqueue_email')) = 5, 'U41 oikeudet kunnossa; ei vanhoja ylikuormia (1 versio per funktio)');
end $$;
