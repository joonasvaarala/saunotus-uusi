-- booking_185: laskutuslukko. Lähetettyä veloituslaskua (status sent/paid/overdue/credited tai locked_at)
-- ei voi enää täydentää: ei uusia tilausrivejä, maksuja, maksulinkkejä eikä lahjakortti-/kumppanikorttikirjauksia.
-- Varauksen siirto, henkilömäärä (henkilökunta) ja peruutus ilman hyvitystä säilyvät; rivit ja summa pysyvät.
-- Omistaja Joonas 26.10.2026, päätökset 1–11, sekä 26.10. 16:44: laskutettuun tilaukseen ei voi enää lisätä mitään.
--   _vc_pay / kumppanilunastus on tämän migraation normaali lukko, ei erillinen valinnainen kohta.
-- Uudet apufunktiot: _order_invoice_locked(bigint), _addon_item_locked(bigint).
-- SECURITY DEFINER, search_path='', REVOKE public/anon/authenticated. Oikeuksia ei myönnetä uudelleen
-- (CREATE OR REPLACE säilyttää proacl). Triggerin _annual_res_discount_trg määrittelyä ei muuteta, vain funktion runko.
-- Vartija on uudelleenajettava: korvattava funktio saa olla vanha tai tämä versio. Riippuvuudet vaaditaan täsmälleen.
-- md5 = md5(pg_get_functiondef). Laskettu paikallisella PG16:lla samalla menetelmällä, joka toisti tuotannon tunnetut md5:t.
-- Ei ajettu Tapio-devissä (PG17). Uudet md5:t on tarkistettava devissä ennen tuotantoa.
-- Rollback: rollbacks/20261026150000_booking_185_ROLLBACK.sql. Testi: tests/talous/t185_invoice_lock.sql.
--
-- Korvattavat (vanha -> uusi):
--   booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text): 285c3e210cf83896d0e726b77de8d068 -> 5b1ed86eabfe27f596d5e6c560df6eb8
--   booking._clamp_addons(bigint,integer): 4d5c4ea6aa2127fee1ba8bb5c8ad3ddc -> 3ebba8f0ea558fca2b62d432011f052f
--   booking._addon_total_after(bigint,integer): 95d05f1d98475a48bdedf00a7b2d3f14 -> aece604d61d16ca4d67a05b521c931fd
--   booking.public_change_treatment_booking(uuid,timestamptz,integer,text): dfcaef15940390a28d8fc0ccfda2c5c6 -> af127177098d1e73fa2a0128b580911b
--   booking._annual_res_discount_trg(): 321df4915ae9ecb347feb3775dff216b -> 4e10525f4d6f052a4ca71a81caa05d8a
--   booking.admin_cancel_reservation(bigint,text,boolean,text): d0f88f33445a8f097f7a1adc5c289c0d -> e627951cee8875cbab0b8ad8b02d8de1
--   booking.public_cancel_booking(uuid): 0a37e720e92f48f70494504c8af3c410 -> e945c67903c5091e418131c16e667c04
--   booking.public_get_booking(uuid): 778f1024006308d0dcd879ef9428ed00 -> 3b9187db7f41c94f5d582fcebb132f23
--   booking._add_to_order(bigint,jsonb,boolean): 200caf6c076a56f93c1c96f0d292fe16 -> c557e6b78fa412a5fa6ee6d1dbdd750b
--   booking._create_link_payment(bigint,integer,text): 5e432077c560a10822db8ac0d2bbe7c2 -> f40db96ca201e40467f20cc1db5866c9
--   booking.admin_record_payment(bigint,text,numeric,text,jsonb): 1e8f6401f9e9f8bd0601636831fb44a0 -> 34a36ce66ce5d5f47a54ddfd0b2ea4b4
--   booking._gc_redeem(bigint,bigint,numeric,text,boolean): a78e6759a28afb8dcf5554823461d03c -> c2ba6303f52474a0b65fe69bd20add96
--   booking.mobilepay_payment_prepare(uuid,uuid,integer,text): 37573920d2f9f882e3d95c4f0c66575f -> e6888446c4b44e554d31c0920609ddb6
--   booking.admin_get_order(bigint): a6029a846cefa829a793ba0b8dbcfaa6 -> 588767e4dd1967267df8d12501aa6898
--   booking.public_get_order(uuid): f570384af308e18227c5909d67f451ab -> c993d12037a9a9269265ba1cb809291e
--   booking.public_upsell_for_order(uuid): 31ee2e995993aaafe06cdb79d7454445 -> a5bf53ee4263a1874d089c0de10c0ae8
--   booking.admin_set_reservation_addons(bigint,jsonb): 55897305ec87eb5a0c016154aa275107 -> a4da46d69ab8e79d6ed69f45a3d8a8ef
--   booking._vc_pay(booking.orders,booking.voucher_claims,numeric): 3c24fd721b0e8bc6f1bdfb8a800c5a0e -> a06c36ba6f27cae4db527ba73eedc5d4
--   booking._attach_addons(bigint,jsonb): 319cac689b7c883bbba857af6b254a3f -> 5bbeefe55f547f8e23a0877f88827a5d
--   booking._ritual_addon_attach(bigint,jsonb): 49199f1464d59a12a735ef5cbe5f339c -> d0db28aec3049e17f225bac836cc9012
--   booking._create_legs_booking(text,bigint,timestamptz,timestamptz,integer,bigint,text,uuid,text,numeric,bigint,boolean,text,boolean,bigint,bigint,text): 5bd306fa23a13ee65abc94d545f3ae1c -> e9a1abf9650dbe9eea153ee0c4d2b5e5
--   booking._create_booking_core(bigint,date,integer,bigint,text,uuid,text,text,text,integer,boolean,timestamptz,timestamptz,numeric,bigint,bigint): acb43265780a8e614a513a0911b1fb05 -> 357a35d3c8d687708d98448b28ce08f4
--   booking._quiet_apply(bigint,jsonb): dd2139dc889d981e6623ef1fceaeec3d -> 02fcdcae63ac31a775e0bf6b66967f0e
--   booking.vismapay_payment_prepare(uuid,uuid): 703c03c301f5a3008192cdbe65e559e2 -> cca997c4e900e78b8bb9e2e0c7da25d4
--   booking.public_upsell_add(uuid,jsonb,uuid,bigint): 97d73b5f177143afb120487ab412779e -> 901f809663b1ffe3362126276213116f
-- Uudet:
--   booking._order_invoice_locked(bigint): 96713008e2d1fce8c81aeda3a2b6b025
--   booking._addon_item_locked(bigint): 26878864894f267ebb97910b7985e5fb
--
-- Lukitut lisäyspolut (order_invoiced, paitsi verkkomaksun valmistelu order_not_payable):
--   admin_set_reservation_addons, _add_to_order (admin_add_to_order, public_add_to_order, public_upsell_add),
--   _attach_addons, _ritual_addon_attach, _create_link_payment, admin_record_payment, _gc_redeem,
--   _vc_pay (kumppanilunastus _vc_redeem -> _vc_mark_redeemed -> _vc_resolve ei nappaa BK001:tä),
--   mobilepay_payment_prepare ja vismapay_payment_prepare (myös dry_run, koodi order_not_payable),
--   _create_legs_booking ja _create_booking_core kun p_order_id viittaa olemassa olevaan tilaukseen,
--   _quiet_apply kun alennus muuttaisi rivin summaa (v_amt > 0).
-- Hinta jäädytetään laskulukossa: _change_booking_core, public_change_treatment_booking,
--   _clamp_addons / _addon_total_after (lukittu lisäpalvelurivi), _annual_res_discount_trg.
-- Asiakkaan henkilömäärän muutos ja public_cancel_booking sekä admin_cancel_reservation(p_refund=true)
--   palauttavat order_invoiced ennen muutosta.
--
-- Tarkistettu ja jätetty ennalleen:
--   _admin_create_legs: luo aina uuden tilauksen (p_order_id null) ja maksun sille.
--   _alloc_payment_lines: payments_paid_trg ja admin_mark_invoice_paid kohdistavat olemassa olevan maksun; esto rikkoisi sallitun laskun kuittauksen.
--   admin_refund, admin_refund_order, admin_mark_invoice_paid, admin_credit_invoice, _invoice_allocate, admin_send_invoice, orders_invoice_draft_trg.
--   admin_set_reservation_status, admin_move_reservation_space, admin_set_reservation_option: vain varaus.
--   public_request_cancel: vain order_requests.
--   _cancel_unpaid_expired_orders: peruu vanhentuneen maksamattoman pidon, ei lisää rivejä eikä osu lähetettyyn laskuun.
--   public_add_to_order, admin_add_to_order, admin_create_payment_link, admin_pos_send_link, _public_pay_json,
--   public_apply_gift_card, admin_redeem_gift_card, _vc_redeem, _vc_mark_redeemed, _vc_resolve: kääreitä, lukko sisemmässä.
--   public_upsell_checkout_attach: vaatii payment_status unpaid, joten lähetetty lasku ei pääse sinne; sisäfunktio on silti lukittu.
--   Uuden tilauksen luonti (public_create_*, admin_create_*, _gc_sell, public_buy_*, _counter_checkout).
--   svc_johku_sync_apply: ulkoinen tuonti, ei henkilökunnan lisäys lähetetylle laskulle.
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text)')));
  if v is null or v not in ('285c3e210cf83896d0e726b77de8d068', '5b1ed86eabfe27f596d5e6c560df6eb8') then ok := false; msg := msg || ' _change_booking_core=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._clamp_addons(bigint,integer)')));
  if v is null or v not in ('4d5c4ea6aa2127fee1ba8bb5c8ad3ddc', '3ebba8f0ea558fca2b62d432011f052f') then ok := false; msg := msg || ' _clamp_addons=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._addon_total_after(bigint,integer)')));
  if v is null or v not in ('95d05f1d98475a48bdedf00a7b2d3f14', 'aece604d61d16ca4d67a05b521c931fd') then ok := false; msg := msg || ' _addon_total_after=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_treatment_booking(uuid,timestamptz,integer,text)')));
  if v is null or v not in ('dfcaef15940390a28d8fc0ccfda2c5c6', 'af127177098d1e73fa2a0128b580911b') then ok := false; msg := msg || ' public_change_treatment_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._annual_res_discount_trg()')));
  if v is null or v not in ('321df4915ae9ecb347feb3775dff216b', '4e10525f4d6f052a4ca71a81caa05d8a') then ok := false; msg := msg || ' _annual_res_discount_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text)')));
  if v is null or v not in ('d0f88f33445a8f097f7a1adc5c289c0d', 'e627951cee8875cbab0b8ad8b02d8de1') then ok := false; msg := msg || ' admin_cancel_reservation=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_cancel_booking(uuid)')));
  if v is null or v not in ('0a37e720e92f48f70494504c8af3c410', 'e945c67903c5091e418131c16e667c04') then ok := false; msg := msg || ' public_cancel_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_get_booking(uuid)')));
  if v is null or v not in ('778f1024006308d0dcd879ef9428ed00', '3b9187db7f41c94f5d582fcebb132f23') then ok := false; msg := msg || ' public_get_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._add_to_order(bigint,jsonb,boolean)')));
  if v is null or v not in ('200caf6c076a56f93c1c96f0d292fe16', 'c557e6b78fa412a5fa6ee6d1dbdd750b') then ok := false; msg := msg || ' _add_to_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v is null or v not in ('5e432077c560a10822db8ac0d2bbe7c2', 'f40db96ca201e40467f20cc1db5866c9') then ok := false; msg := msg || ' _create_link_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_record_payment(bigint,text,numeric,text,jsonb)')));
  if v is null or v not in ('1e8f6401f9e9f8bd0601636831fb44a0', '34a36ce66ce5d5f47a54ddfd0b2ea4b4') then ok := false; msg := msg || ' admin_record_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._gc_redeem(bigint,bigint,numeric,text,boolean)')));
  if v is null or v not in ('a78e6759a28afb8dcf5554823461d03c', 'c2ba6303f52474a0b65fe69bd20add96') then ok := false; msg := msg || ' _gc_redeem=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)')));
  if v is null or v not in ('37573920d2f9f882e3d95c4f0c66575f', 'e6888446c4b44e554d31c0920609ddb6') then ok := false; msg := msg || ' mobilepay_payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_get_order(bigint)')));
  if v is null or v not in ('a6029a846cefa829a793ba0b8dbcfaa6', '588767e4dd1967267df8d12501aa6898') then ok := false; msg := msg || ' admin_get_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_get_order(uuid)')));
  if v is null or v not in ('f570384af308e18227c5909d67f451ab', 'c993d12037a9a9269265ba1cb809291e') then ok := false; msg := msg || ' public_get_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_upsell_for_order(uuid)')));
  if v is null or v not in ('31ee2e995993aaafe06cdb79d7454445', 'a5bf53ee4263a1874d089c0de10c0ae8') then ok := false; msg := msg || ' public_upsell_for_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_set_reservation_addons(bigint,jsonb)')));
  if v is null or v not in ('55897305ec87eb5a0c016154aa275107', 'a4da46d69ab8e79d6ed69f45a3d8a8ef') then ok := false; msg := msg || ' admin_set_reservation_addons=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_pay(booking.orders,booking.voucher_claims,numeric)')));
  if v is null or v not in ('3c24fd721b0e8bc6f1bdfb8a800c5a0e', 'a06c36ba6f27cae4db527ba73eedc5d4') then ok := false; msg := msg || ' _vc_pay=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._attach_addons(bigint,jsonb)')));
  if v is null or v not in ('319cac689b7c883bbba857af6b254a3f', '5bbeefe55f547f8e23a0877f88827a5d') then ok := false; msg := msg || ' _attach_addons=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._ritual_addon_attach(bigint,jsonb)')));
  if v is null or v not in ('49199f1464d59a12a735ef5cbe5f339c', 'd0db28aec3049e17f225bac836cc9012') then ok := false; msg := msg || ' _ritual_addon_attach=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_legs_booking(text,bigint,timestamptz,timestamptz,integer,bigint,text,uuid,text,numeric,bigint,boolean,text,boolean,bigint,bigint,text)')));
  if v is null or v not in ('5bd306fa23a13ee65abc94d545f3ae1c', 'e9a1abf9650dbe9eea153ee0c4d2b5e5') then ok := false; msg := msg || ' _create_legs_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_booking_core(bigint,date,integer,bigint,text,uuid,text,text,text,integer,boolean,timestamptz,timestamptz,numeric,bigint,bigint)')));
  if v is null or v not in ('acb43265780a8e614a513a0911b1fb05', '357a35d3c8d687708d98448b28ce08f4') then ok := false; msg := msg || ' _create_booking_core=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._quiet_apply(bigint,jsonb)')));
  if v is null or v not in ('dd2139dc889d981e6623ef1fceaeec3d', '02fcdcae63ac31a775e0bf6b66967f0e') then ok := false; msg := msg || ' _quiet_apply=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v is null or v not in ('703c03c301f5a3008192cdbe65e559e2', 'cca997c4e900e78b8bb9e2e0c7da25d4') then ok := false; msg := msg || ' vismapay_payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_upsell_add(uuid,jsonb,uuid,bigint)')));
  if v is null or v not in ('97d73b5f177143afb120487ab412779e', '901f809663b1ffe3362126276213116f') then ok := false; msg := msg || ' public_upsell_add=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_invoice_locked(bigint)')));
  if v is not null and v <> '96713008e2d1fce8c81aeda3a2b6b025' then ok := false; msg := msg || ' _order_invoice_locked=' || v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._addon_item_locked(bigint)')));
  if v is not null and v <> '26878864894f267ebb97910b7985e5fb' then ok := false; msg := msg || ' _addon_item_locked=' || v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v is null or v <> '647c556562046c75b7e7e33703c050a0' then ok := false; msg := msg || ' public_payment_link_info=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._public_pay_json(bigint)')));
  if v is null or v <> 'cc3e61dbdfbd9a816cd9c982c73820c5' then ok := false; msg := msg || ' _public_pay_json=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_send_link(bigint,text,boolean)')));
  if v is null or v <> '735e92d8c8c52784bbba9b928c5a122b' then ok := false; msg := msg || ' admin_pos_send_link=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)')));
  if v is null or v <> '5babbf859133aebd3e9e7c827bee3261' then ok := false; msg := msg || ' admin_add_to_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_create_payment_link(bigint,boolean,integer,text)')));
  if v is null or v <> '80004933a80f77a10fcf625f493a20ef' then ok := false; msg := msg || ' admin_create_payment_link=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_add_to_order(uuid,jsonb)')));
  if v is null or v <> 'a7eaf138bff841c31f35ca4961065d12' then ok := false; msg := msg || ' public_add_to_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_change_booking(bigint,bigint,date,integer)')));
  if v is null or v <> 'cdf486f3a1a24e50427037a7f853610d' then ok := false; msg := msg || ' admin_change_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_booking(uuid,bigint,date,integer)')));
  if v is null or v <> 'd2ccd2fd798f8a2f8784b9bf8ce5887f' then ok := false; msg := msg || ' public_change_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_order_time(uuid,bigint,timestamptz,bigint,date,integer,text)')));
  if v is null or v <> '5c5d195c5720d872dbbf9f97a49f2558' then ok := false; msg := msg || ' public_change_order_time=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_set_reservation_status(bigint,text,text)')));
  if v is null or v <> 'aed4b0d7e19f7c13d1ac91c28cc0b642' then ok := false; msg := msg || ' admin_set_reservation_status=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_move_reservation_space(bigint,text,text)')));
  if v is null or v <> 'ca6a5627e83cb0cf68f6e1c4633ce458' then ok := false; msg := msg || ' admin_move_reservation_space=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_set_reservation_option(bigint,text,boolean)')));
  if v is null or v <> '2144d372822f1daf8f7b3c37a3643be3' then ok := false; msg := msg || ' admin_set_reservation_option=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_request_cancel(uuid,text)')));
  if v is null or v <> '99139f708a2733dba1373759686f630c' then ok := false; msg := msg || ' public_request_cancel=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._refresh_order_payment(bigint)')));
  if v is null or v <> '84e6c0a9c5ed6eb64234e8cdf859fbff' then ok := false; msg := msg || ' _refresh_order_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._cancel_unpaid_expired_orders()')));
  if v is null or v <> '786c1cfff97bade7fdedc44001182214' then ok := false; msg := msg || ' _cancel_unpaid_expired_orders=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._invoice_allocate(bigint)')));
  if v is null or v <> '46a3326812f896077fc2614ba783ff3d' then ok := false; msg := msg || ' _invoice_allocate=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_send_invoice(bigint,boolean,boolean)')));
  if v is null or v <> '7ea29743e8e199c74ced1d62c730b27f' then ok := false; msg := msg || ' admin_send_invoice=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_credit_invoice(bigint)')));
  if v is null or v <> '148ef7df93eb4fa8f4face55380bf8b1' then ok := false; msg := msg || ' admin_credit_invoice=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_uncovered(bigint,boolean)')));
  if v is null or v <> 'c3dd10fe675fb3f1a67cec07cf02c24c' then ok := false; msg := msg || ' _order_uncovered=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_balance(bigint)')));
  if v is null or v <> 'a6b31f93559de53d75a52d8a285f1170' then ok := false; msg := msg || ' _order_balance=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._addon_limit(integer,integer)')));
  if v is null or v <> '8addb644ba4d21644192df98576aad0a' then ok := false; msg := msg || ' _addon_limit=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_redeem_gift_card(bigint,text,numeric,text)')));
  if v is null or v <> '1e88e8db70f1a60f076e06d2f773df90' then ok := false; msg := msg || ' admin_redeem_gift_card=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_apply_gift_card(uuid,text,numeric)')));
  if v is null or v <> '408bf21b62cb7385dca39079c4f22907' then ok := false; msg := msg || ' public_apply_gift_card=' || coalesce(v, 'puuttuu'); end if;
  if not ok then raise exception 'booking_185: tuotannon määrittelyt eivät vastaa odotettua:%. Ei muutoksia.', msg; end if;
end $g$;


CREATE OR REPLACE FUNCTION booking._order_invoice_locked(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM booking.invoices i
    WHERE i.order_id = p_order_id AND i.kind = 'debit'
      AND (i.status IN ('sent','paid','overdue','credited') OR i.locked_at IS NOT NULL)
  );
$function$;

CREATE OR REPLACE FUNCTION booking._addon_item_locked(p_item_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT
    COALESCE((SELECT SUM(pl.amount_gross - pl.refunded_gross)
              FROM booking.payment_lines pl
              JOIN booking.payments p ON p.id = pl.payment_id
              WHERE pl.order_item_id = p_item_id
                AND p.status IN ('paid','partially_refunded','refunded')), 0) > 0.004
    OR EXISTS(SELECT 1 FROM booking.payment_lines pl
              JOIN booking.payments p ON p.id = pl.payment_id
              WHERE pl.order_item_id = p_item_id
                AND p.status = 'pending' AND p.provider <> 'manual');
$function$;

REVOKE ALL ON FUNCTION booking._order_invoice_locked(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION booking._addon_item_locked(bigint) FROM PUBLIC, anon, authenticated;

create or replace function booking._change_booking_core(
  p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer,
  p_enforce_deadline boolean, p_notice_hours integer, p_actor uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  res booking.reservations; o booking.orders; rs record; pr record; v_keep boolean := (p_rule_id is null and p_date is null);
  v_persons integer; v_rule bigint; v_total numeric; v_paid numeric; v_old booking.reservations; v_addons numeric; v_order_total numeric;
  v_locked boolean;
begin
  if (p_rule_id is null) <> (p_date is null) then perform booking._err('invalid_change', 'Anna sekä uusi vuoro että päivä, tai kumpikaan'); end if;
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  select * into o from booking.orders where id = res.order_id;
  v_locked := booking._order_invoice_locked(o.id);
  if res.status <> 'confirmed' or o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistettua varausta voi muuttaa');
  end if;
  if v_locked and p_notice_hours is not null and coalesce(p_persons, res.persons) <> res.persons then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if p_notice_hours is not null and res.starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen vuoron alkua – ota yhteyttä sähköpostitse', p_notice_hours));
  end if;
  v_old := res;
  v_persons := coalesce(p_persons, res.persons);
  v_rule := coalesce(p_rule_id, res.rule_id);

  if v_keep then   -- vain henkilömäärä: aika, tila ja poolit säilyvät
    select * into rs from booking._resolve_session(v_rule, null, v_persons, false, res.starts_at, res.ends_at, true);
  else
    select * into rs from booking._resolve_session(v_rule, p_date, v_persons, p_enforce_deadline);
  end if;
  if rs.o_product_id is distinct from res.product_id then
    perform booking._err('product_mismatch', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon');
  end if;
  if p_notice_hours is not null and rs.o_starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Uuden vuoron pitää alkaa vähintään %s tuntia päästä', p_notice_hours));
  end if;

  if not v_locked then
    select * into pr from booking._rule_price(v_rule, v_persons);
    v_total := case when res.annual_card_id is not null then 0 else pr.total end;
    v_addons := booking._addon_total_after(res.order_item_id, v_persons);   -- lisäpalvelut uudella henkilömäärällä (määrät rajataan)
    select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) into v_paid from booking.payments where order_id = o.id;
    if p_notice_hours is not null and v_paid > 0 and (v_total + v_addons) is distinct from o.total_gross then
      perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan');
    end if;
  end if;

  -- trigger reservations_validate tarkistaa kaiken (lukko, päällekkäisyys, kapasiteetti, sulku, vuosikortti)
  update booking.reservations set rule_id = v_rule, space_id = rs.o_space_id, mode = rs.o_mode, starts_at = rs.o_starts_at,
         ends_at = rs.o_ends_at, persons = v_persons, pool_ids = rs.o_pool_ids
   where id = res.id returning * into res;

  if not v_locked then
    update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total,
           price_breakdown = pr.breakdown || jsonb_build_object('rule_id', v_rule, 'rule_label', (select label from booking.schedule_rules where id = v_rule))
     where id = res.order_item_id;
    perform booking._clamp_addons(res.order_item_id, v_persons);
    update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id
      returning total_gross into v_order_total;
    update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
    perform booking._refresh_order_payment(o.id);
  else
    v_order_total := o.total_gross;
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (p_actor, booking._jwt_role(), 'reservations', res.id::text, p_via, to_jsonb(v_old),
          case when v_locked then to_jsonb(res) || jsonb_build_object('invoice_locked', true) else to_jsonb(res) end);

  return jsonb_build_object('reservation_id', res.id, 'order_id', o.id, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at,
                            'persons', res.persons, 'total', v_order_total, 'rule_id', v_rule, 'product_id', res.product_id)
         || case when v_locked then jsonb_build_object('invoice_locked', true) else '{}'::jsonb end;
end $$;

create or replace function booking._clamp_addons(p_item_id bigint, p_persons integer)
returns void language plpgsql security definer set search_path = '' as $$
declare q record; v_lim integer;
begin
  for q in select it.id, it.quantity, it.unit_price_gross, a.max_per_person from booking.order_items it join booking.addons a on a.id = it.addon_id
            where it.parent_item_id = p_item_id and it.kind = 'addon' loop
    if booking._addon_item_locked(q.id) then continue; end if;
    v_lim := booking._addon_limit(q.max_per_person, p_persons);
    if q.quantity > v_lim then
      update booking.order_items set quantity = v_lim, line_total_gross = q.unit_price_gross * v_lim,
             price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('quantity', v_lim, 'clamped_from', q.quantity)
       where id = q.id;
    end if;
  end loop;
end $$;

create or replace function booking._addon_total_after(p_item_id bigint, p_persons integer)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(
           case when booking._addon_item_locked(it.id) then it.line_total_gross
                else it.unit_price_gross * least(it.quantity, booking._addon_limit(a.max_per_person, p_persons)) end), 0)
    from booking.order_items it join booking.addons a on a.id = it.addon_id
   where it.parent_item_id = p_item_id and it.kind = 'addon'
$$;

CREATE OR REPLACE FUNCTION booking.public_change_treatment_booking(p_token uuid, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_persons integer DEFAULT NULL::integer, p_option_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; res booking.reservations; v_old booking.reservations; v_n int; v_res_id bigint; v_detail text; v_msg text; v_code text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_start timestamptz; v_end timestamptz; v_persons integer; v_total numeric; v_paid numeric; v_order_total numeric; v_item bigint; v_opt bigint; v_locked boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chg:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if p_start is null and p_persons is null and nullif(btrim(coalesce(p_option_code, '')), '') is null then return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi aika, henkilömäärä ja/tai hoito'); end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  begin
    select * into res from booking.reservations where id = v_res_id for update;
    if res.rule_id is not null or o.source_channel <> 'web' or not exists (select 1 from booking.product_config pc where pc.product_id = res.product_id and pc.public_slots) then
      return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
    end if;
    v_locked := booking._order_invoice_locked(o.id);
    if v_locked and coalesce(p_persons, res.persons) <> res.persons then
      return jsonb_build_object('ok', false, 'code', 'order_invoiced', 'message', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
    end if;
    v_old := res;
    if nullif(btrim(coalesce(p_option_code, '')), '') is not null then v_opt := booking._resolve_product_option(res.product_id, p_option_code, true); end if;     -- booking_50: tuotevalinnan vaihto (invalid_option)
    if res.starts_at - make_interval(hours => v_hours) < now() then
      perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen alkua – ota yhteyttä sähköpostitse', v_hours));
    end if;
    v_start := coalesce(p_start, res.starts_at);
    v_persons := coalesce(p_persons, res.persons);
    if p_start is not null and v_start - make_interval(hours => v_hours) < now() then
      perform booking._err('change_too_late', format('Uuden ajan pitää alkaa vähintään %s tuntia päästä', v_hours));
    end if;
    v_end := booking._treatment_slot_check(res.product_id, v_start, v_persons, false);
    -- sama tila (ei vaihdeta tilaa omatoimisesti): suunnitelma validoi rajat ja päällekkäisyydet (oma varaus jätetään huomiotta); saunottajaa ei vaadita
    perform 1 from booking._plan_legs(res.product_id, v_start, v_end, v_persons, res.space_id, false, res.id, true);
    if not v_locked then
      v_total := booking._treatment_price(res.product_id, v_persons);
      select coalesce(sum(amount) filter (where status in ('paid', 'partially_refunded', 'refunded')), 0) into v_paid from booking.payments where order_id = o.id;
      if v_paid > 0 and v_total is distinct from o.total_gross then perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan'); end if;
    end if;
    begin
      update booking.reservations set starts_at = v_start, ends_at = v_end, persons = v_persons, product_option_id = coalesce(v_opt, product_option_id) where id = res.id returning * into res;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail;
      if v_code is distinct from 'no_therapist' then raise; end if;
      -- uudella ajalla ei vapaata saunottajaa: poistetaan saunottajaleg ja merkitään therapist_missing (ilmoitus Tapiolle triggerillä)
      delete from booking.reservation_legs where reservation_id = res.id and role = 'therapist';
      update booking.reservations set starts_at = v_start, ends_at = v_end, persons = v_persons, therapist_missing = true, product_option_id = coalesce(v_opt, product_option_id) where id = res.id returning * into res;
    end;
    if not v_locked then
      select id into v_item from booking.order_items where id = res.order_item_id;
      update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total where id = v_item;
      update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id returning total_gross into v_order_total;
      update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
      perform booking._refresh_order_payment(o.id);
    else
      v_order_total := o.total_gross;
    end if;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (null, booking._jwt_role(), 'reservations', res.id::text, 'CUSTOMER_CHANGE', to_jsonb(v_old), to_jsonb(res));
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at, 'persons', res.persons, 'total', v_order_total, 'option', booking._option_json(res.product_option_id));
end $function$;

create or replace function booking._annual_res_discount_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_full numeric;
begin
  if booking._order_invoice_locked(new.order_id) then return null; end if;
  if new.rule_id is null or new.order_item_id is null then return null; end if;
  begin
    select total into v_full from booking._rule_price(new.rule_id, new.persons);
  exception when others then return null;   -- hinnaton sääntö: ei kaadeta varausta, alennus jää ennalleen
  end;
  update booking.order_items set discount_amount = coalesce(v_full, 0)
   where id = new.order_item_id and kind = 'reservation' and discount_code_id is null and line_total_gross = 0
     and discount_amount is distinct from coalesce(v_full, 0);
  return null;
end $$;

create or replace function booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text default null,
  p_refund boolean default false, p_refund_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_refund, false) then perform booking._require_permission('payments.refund'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if r.status not in ('pending','confirmed') then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;
  if coalesce(p_refund, false) and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if coalesce(p_refund, false) then v_plan := booking._reservation_refund_plan(r.id); end if;   -- ennen peruutusta (rivit eivät muutu)
  perform booking.admin_set_reservation_status(r.id, 'cancelled', coalesce(nullif(btrim(p_reason), ''), 'henkilökunta'));
  if coalesce(p_refund, false) then
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen peruutus (varaus #' || r.id || ')');
    for x in select * from jsonb_array_elements(v_plan -> 'payments') loop
      v_res := booking.admin_refund((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, v_reason, x -> 'lines', false);
      v_out := v_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'provider', x ->> 'provider', 'amount', (x ->> 'amount')::numeric,
        'refund_id', v_res -> 'refund_id', 'status', v_res ->> 'status', 'receipt_no', v_res -> 'receipt_no');
      v_total := v_total + (x ->> 'amount')::numeric;
    end loop;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', coalesce(p_refund, false), 'refunded_total', v_total));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'balance', booking._order_balance(r.order_id));
end $$;

CREATE OR REPLACE FUNCTION booking.public_cancel_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; n int;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
begin
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if booking._order_invoice_locked(o.id) then
    return jsonb_build_object('ok', false, 'code', 'order_invoiced', 'message', 'Tilaus on laskutettu – peruutus tehdään henkilökunnan kautta');
  end if;
  -- booking_54: MobilePay-maksu kesken => ei peruuteta (raha menisi hukkaan); asiakas odottaa maksun lopputulosta
  if o.status = 'pending' and booking._order_mp_inflight(o.id) then
    return jsonb_build_object('ok', false, 'code', 'payment_in_progress', 'message', 'Maksu on kesken – odota hetki ja yritä uudelleen');
  end if;
  update booking.reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = 'customer_cancelled_pending'
   where order_id = o.id and status = 'pending';
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('ok', false, 'code', 'not_cancellable',
      'message', format('Vahvistetun varauksen peruutus tehdään sähköpostitse henkilökunnalle. Varausta voi muuttaa itse viimeistään %s tuntia ennen vuoron alkua.', v_hours));
  end if;
  update booking.orders set status = 'cancelled', cancelled_at = now() where id = o.id and status = 'pending';
  update booking.payments set status = 'cancelled' where order_id = o.id and status = 'pending';
  perform booking._checkout_release_gift_cards(array[o.id]);   -- booking_54: lahjakorttiosamaksut palautetaan kortille
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode, 'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at,
           'ritual_addon', booking._is_ritual_addon_item(it.id))   -- booking_166: vuoron lisäpalveluna varattu saunarituaali (näytetään vuoron jälkeen)
         order by booking._is_ritual_addon_item(it.id), r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'has_ritual_addon', exists (select 1 from booking.order_items x where x.order_id = o.id and x.kind = 'reservation' and booking._is_ritual_addon_item(x.id)),
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end,
           'invoice_locked', booking._order_invoice_locked(o.id))
         || booking._checkout_state_json(o.id);
end $function$;

CREATE OR REPLACE FUNCTION booking._add_to_order(p_order_id bigint, p_items jsonb, p_staff boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; e jsonb; v_type text; v_added jsonb := '[]'::jsonb; v_total0 numeric; v_end timestamptz; v_res booking.reservations; a booking.addons; v_qty int; v_cur int; v_lim int;
  v_item bigint; p kb.products; pc booking.product_config; v_resid bigint; v_n int; v_r jsonb; v_pid bigint; v_start timestamptz; v_en timestamptz; v_line numeric; v_vat numeric; v_amt numeric;
  v_desc text; v_ovr boolean; v_chan text := case when p_staff then 'admin' else 'web' end; v_price numeric; v_add numeric; v_idtxt text; v_code text; v_mode text; v_rid bigint;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if o.external_source is not null or not (o.status = 'confirmed' or (p_staff and o.status = 'completed')) then perform booking._err('order_not_editable', 'Tilaukseen ei voi lisätä'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then perform booking._err('invalid_items', 'Anna 1–20 lisättävää riviä'); end if;
  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  if not p_staff and (v_end is null or v_end <= now()) then perform booking._err('order_closed', 'Lisäysaika on päättynyt'); end if;
  v_total0 := o.total_gross;

  for e in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_items', 'Rivi väärässä muodossa'); end if;
    v_type := e ->> 'type';
    if v_type = 'addon' then
      if coalesce(e ->> 'reservation_id', '') ~ '^\d{1,18}$' then v_resid := (e ->> 'reservation_id')::bigint;
      elsif e ->> 'reservation_id' is not null then perform booking._err('item_not_found', 'Varausta ei löydy');
      else
        select count(*), min(r.id) into v_n, v_resid from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
        if v_n <> 1 then perform booking._err('invalid_items', 'Anna reservation_id'); end if;
      end if;
      select * into v_res from booking.reservations where id = v_resid and order_id = o.id;
      if not found then perform booking._err('item_not_found', 'Varausta ei löydy tilauksesta'); end if;
      if not booking._res_active(v_res.status, v_res.hold_expires_at) then perform booking._err('order_not_editable', 'Varaus ei ole voimassa'); end if;
      if not p_staff and v_res.ends_at <= now() then perform booking._err('order_closed', 'Lisäysaika on päättynyt'); end if;
      v_idtxt := e ->> 'addon_id'; v_code := e ->> 'code';
      if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
      select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
      if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
      if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or (e ->> 'quantity')::int = 0 then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
      v_qty := (e ->> 'quantity')::int;
      select coalesce(sum(quantity), 0) into v_cur from booking.order_items where parent_item_id = v_res.order_item_id and addon_id = a.id and kind = 'addon';
      v_lim := booking._addon_limit(a.max_per_person, v_res.persons);
      if v_cur + v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi olla enintään %s kpl (nyt %s)', a.name, v_lim, v_cur)); end if;
      perform booking._attach_addons(v_res.id, jsonb_build_array(jsonb_build_object('id', a.id, 'quantity', v_qty)));
      select max(id) into v_item from booking.order_items where parent_item_id = v_res.order_item_id and addon_id = a.id;
      select line_total_gross into v_line from booking.order_items where id = v_item;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', a.name, 'line_total', v_line, 'reservation_id', v_res.id);

    elsif v_type = 'reservation' then
      v_add := 0; v_rid := null;
      if e ? 'product_id' then
        if coalesce(e ->> 'product_id', '') !~ '^\d{1,18}$' then perform booking._err('invalid_items', 'product_id virheellinen'); end if;
        v_pid := (e ->> 'product_id')::bigint;
        if coalesce(e ->> 'persons', '') !~ '^\d{1,3}$' then perform booking._err('invalid_items', 'persons virheellinen'); end if;
        v_start := (e ->> 'start')::timestamptz; v_en := nullif(e ->> 'end', '')::timestamptz;
        v_ovr := coalesce((e ->> 'override')::boolean, false);
        if not p_staff then
          select * into pc from booking.product_config where product_id = v_pid;
          if not found or not pc.bookable or not pc.shop_visible or not pc.public_slots or e ? 'price' or e ? 'space_id' or e ? 'parent_reservation_id' or v_ovr then
            perform booking._err('invalid_items', 'Tuotetta ei voi lisätä verkossa');
          end if;
          if v_start is null or v_start < now() then perform booking._err('bad_time', 'Virheellinen aika'); end if;
        elsif v_ovr and not booking.has_permission('bookings.override') then perform booking._err('forbidden', 'Ei oikeutta ylitykseen (bookings.override)');
        end if;
        v_price := case when p_staff and e ? 'price' then (e ->> 'price')::numeric end;
        if v_price is not null and v_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
        v_r := booking._create_legs_booking('current', v_pid, v_start, v_en, (e ->> 'persons')::int, o.customer_id, v_chan, auth.uid(), null, v_price,
                 nullif(e ->> 'space_id', '')::bigint, v_ovr, e ->> 'override_reason', false, nullif(e ->> 'parent_reservation_id', '')::bigint, o.id, e ->> 'option_code');
      elsif e ? 'rule_id' then
        if coalesce(e ->> 'rule_id', '') !~ '^\d{1,18}$' or coalesce(e ->> 'persons', '') !~ '^\d{1,3}$' then perform booking._err('invalid_items', 'rule_id/persons virheellinen'); end if;
        v_r := booking._create_booking_core((e ->> 'rule_id')::bigint, (e ->> 'date')::date, (e ->> 'persons')::int, o.customer_id, v_chan, auth.uid(), o.locale, null,
                 'confirmed', null, not p_staff, null, null, null, null, o.id);
      else perform booking._err('invalid_items', 'Varausrivillä pitää olla product_id tai rule_id');
      end if;
      v_rid := (v_r ->> 'reservation_id')::bigint;
      if e ? 'addons' then v_add := booking._attach_addons(v_rid, e -> 'addons'); end if;
      select order_item_id into v_item from booking.reservations where id = v_rid;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', v_r ->> 'product_name', 'line_total', (v_r ->> 'total')::numeric + v_add, 'reservation_id', v_rid);

    elsif v_type = 'product' then
      if coalesce(e ->> 'product_id', '') !~ '^\d{1,18}$' or coalesce(e ->> 'quantity', '') !~ '^\d{1,2}$' or (e ->> 'quantity')::int = 0 then perform booking._err('invalid_items', 'Tuote/määrä virheellinen'); end if;
      select * into p from kb.products where id = (e ->> 'product_id')::bigint and active;
      if not found or p.category <> 'product_rental' then perform booking._err('item_not_found', 'Tuotetta ei löydy / ei lisättävissä'); end if;
      if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
      if p.price is null then perform booking._err('invalid_items', 'Tuotteella ei ole hintaa'); end if;
      v_qty := (e ->> 'quantity')::int; v_line := p.price * v_qty;
      insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
      values (o.id, p.id, p.name, 'product', v_qty, p.price, v_line, p.vat_rate, jsonb_build_object('model', 'add_to_order')) returning id into v_item;
      update booking.orders set total_gross = total_gross + v_line where id = o.id;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', p.name, 'line_total', v_line);

    elsif v_type = 'custom' then
      if not p_staff then perform booking._err('invalid_items', 'Rivityyppi ei ole sallittu'); end if;
      if not booking.has_permission('bookings.override') then perform booking._err('forbidden', 'Vapaa rivi vaatii oikeuden bookings.override'); end if;
      v_desc := btrim(coalesce(e ->> 'description', ''));
      if char_length(v_desc) not between 3 and 120 then perform booking._err('invalid_items', 'Kuvaus 3–120 merkkiä'); end if;
      if coalesce(e ->> 'amount', '') !~ '^-?\d{1,5}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Summa virheellinen'); end if;
      v_amt := (e ->> 'amount')::numeric;
      if v_amt = 0 then perform booking._err('invalid_items', 'Summa ei voi olla 0'); end if;
      if coalesce(e ->> 'vat_rate', '') !~ '^\d{1,3}(\.\d{1,2})?$' then perform booking._err('invalid_vat', 'ALV-kanta puuttuu'); end if;
      v_vat := (e ->> 'vat_rate')::numeric;
      if not booking._vat_active(v_vat) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu'); end if;
      v_qty := coalesce(nullif(e ->> 'quantity', '')::int, 1);
      if v_qty not between 1 and 99 then perform booking._err('invalid_items', 'Määrä 1–99'); end if;
      v_line := v_amt * v_qty;
      if (select total_gross from booking.orders where id = o.id) + v_line < 0 then perform booking._err('invalid_items', 'Alennus ylittää tilauksen summan'); end if;
      insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
      values (o.id, v_desc, case when v_amt < 0 then 'discount' else 'fee' end, v_qty, v_amt, v_line, v_vat, jsonb_build_object('model', 'custom_line')) returning id into v_item;
      update booking.orders set total_gross = total_gross + v_line where id = o.id;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', v_desc, 'line_total', v_line);
    else
      perform booking._err('invalid_items', 'Tuntematon rivityyppi');
    end if;
  end loop;

  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, case when p_staff then 'ADMIN_ADD_TO_ORDER' else 'CUSTOMER_ADD_TO_ORDER' end,
          jsonb_build_object('total', v_total0), jsonb_build_object('items', p_items, 'added', v_added, 'total', (select total_gross from booking.orders where id = o.id)));
  return jsonb_build_object('added', v_added, 'added_total', (select total_gross from booking.orders where id = o.id) - v_total0);
end $function$;

CREATE OR REPLACE FUNCTION booking._create_link_payment(p_order_id bigint, p_expires_days integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_184: p_expires_days null = maksulinkki ilman takarajaa (link_expires_at null, raw.paylink = 'no_deadline'); muuten 1–60 päivää kuten ennen.
-- Uudelleenkäyttö (sama summa, yksi avoin Visma-rivi): takarajaton pyyntö käyttää vain merkittyä takarajatonta linkkiä; takarajallinen pyyntö käyttää
-- avointa riviä kuten ennen, paitsi henkilökunta (is_staff) korvaa takarajattoman linkin takarajallisella. Asiakkaan/järjestelmän polut eivät siis peru
-- henkilökunnan takarajatonta linkkiä, kun summa ei muutu.
declare o booking.orders; v_tot numeric; v_open booking.payments; v_n int; v_id bigint; v_token uuid; v_exp timestamptz; v_unpaid numeric; v_open_nd boolean;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi luoda maksulinkkiä'); end if;
  if p_expires_days is not null and (p_expires_days < 1 or p_expires_days > 60) then perform booking._err('invalid_param', 'Linkin voimassaolo 1–60 päivää'); end if;
  select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  v_tot := least(v_tot, v_unpaid);
  if v_tot <= 0.004 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  select count(*) into v_n from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
  if v_n = 1 then
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
    v_open_nd := v_open.link_expires_at is null and coalesce(v_open.raw ->> 'paylink', '') = 'no_deadline';
    if v_open.amount = v_tot and (case when p_expires_days is null then v_open_nd
                                       when v_open_nd then not booking.is_staff()
                                       else true end) then
      return jsonb_build_object('payment_id', v_open.id, 'link_token', v_open.link_token, 'amount', v_open.amount, 'expires_at', v_open.link_expires_at, 'reused', true);
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella maksulinkillä')
   where order_id = o.id and status = 'pending' and provider = 'visma_pay';
  v_exp := case when p_expires_days is null then null else now() + make_interval(days => p_expires_days) end;
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, raw, note, created_by)
  values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, v_exp,
          case when v_exp is null then jsonb_build_object('paylink', 'no_deadline') end, p_note, auth.uid()) returning id, link_token into v_id, v_token;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
  select v_id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
  -- jos rivit ylittävät jäännöksen (poikkeus: hyvitetty/poistettu rivi), pienennetään suurinta riviä
  update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = v_id) - v_tot)
   where id = (select id from booking.payment_lines where payment_id = v_id order by amount_gross desc, id limit 1)
     and (select sum(amount_gross) from booking.payment_lines where payment_id = v_id) > v_tot;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('payment_id', v_id, 'link_token', v_token, 'amount', v_tot, 'expires_at', v_exp, 'reused', false);
end $function$
;

create or replace function booking.admin_record_payment(p_order_id bigint, p_method text, p_amount numeric, p_note text default null, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; v_pm booking.payment_methods; v_id bigint; v_unpaid numeric; l jsonb; v_it record; v_sum numeric := 0; v_rem numeric; v_round numeric; rc record;
begin
  perform booking._require_permission('payments.manage');
  if p_method = 'cash' then perform booking._err('cash_not_accepted', 'Käteistä ei oteta vastaan'); end if;
  select * into v_pm from booking.payment_methods where code = p_method and active and is_manual;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä / ei käsin kirjattava'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if p_amount > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu käsin kirjatulla maksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  v_round := 0;
  insert into booking.payments(order_id, method, provider, status, amount, rounding, note, created_by)
  values (o.id, p_method, 'manual', 'pending', p_amount, v_round, p_note, auth.uid()) returning id into v_id;
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'item_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_it from booking._order_uncovered(o.id, false) u where u.item_id = (l ->> 'item_id')::bigint;
      if not found then perform booking._err('item_not_found', 'Riviä ei löydy tai se on jo maksettu'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_it.remaining + 0.004 then perform booking._err('invalid_items', 'Rivin summa ylittää maksamattoman osuuden'); end if;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      values (v_id, v_it.item_id, v_it.description, v_it.kind, case when (l ->> 'amount')::numeric = v_it.remaining then v_it.quantity else 1 end, (l ->> 'amount')::numeric, v_it.vat_rate);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa maksun summaa'); end if;
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'balance', booking._order_balance(o.id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no,
                            'rounding', (select rounding from booking.payments where id = v_id));
end $$;

CREATE OR REPLACE FUNCTION booking._gc_redeem(p_order_id bigint, p_card_id bigint, p_amount numeric, p_note text, p_public boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; g booking.gift_cards; v_unpaid numeric; v_amt numeric; v_id bigint; rc record; v_excl boolean; v_card booking.gift_cards; v_rest numeric; v_confirmed boolean := false;
        v_own boolean; v_ok numeric; v_left numeric; v_use numeric; ur record;
begin
  if not booking._gc_flag('gift_cards.redeem_enabled') then perform booking._err('redeem_disabled', 'Lahjakorttien lunastus ei ole vielä käytössä'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if p_public and o.status = 'expired' then perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus'); end if;
  if p_public and o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_preliminary', 'Alustava varaus: maksu pyydetään vahvistuksen jälkeen'); end if;
  if p_public and o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now())
     and not booking._order_mp_inflight(o.id) then
    perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus');
  end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed') or (p_public and o.status = 'completed') then
    perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
  end if;
  if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;
  select * into g from booking.gift_cards where id = p_card_id for update;
  if not found then perform booking._err('gift_card_not_found', 'Korttia ei löydy'); end if;
  if g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then
    perform booking._err('johku_cards_closed', 'Johku-lähtöisten korttien lunastus ei ole vielä käytössä (kortit lunastetaan toistaiseksi Johkussa)');
  end if;
  if g.status in ('cancelled', 'pending_payment', 'pending_verification') then perform booking._err('gift_card_inactive', 'Kortti ei ole käytettävissä'); end if;
  if g.status = 'expired' or (g.valid_to is not null and g.valid_to < booking._gc_today()) then perform booking._err('gift_card_expired', 'Kortin voimassaolo on päättynyt'); end if;
  if g.status = 'used' or g.balance <= 0 then perform booking._err('gift_card_empty', 'Kortin saldo on käytetty'); end if;
  if not g.balance_verified then perform booking._err('gift_card_inactive', 'Kortin saldoa ei ole vahvistettu'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
  v_amt := coalesce(p_amount, least(g.balance, v_unpaid));
  if v_amt is null or v_amt <= 0 or v_amt <> round(v_amt, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  if v_amt > g.balance + 0.004 then perform booking._err('insufficient_balance', format('Kortin saldo on %s €', g.balance)); end if;
  if v_amt > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  v_own := g.source is distinct from 'johku' and g.accounting_origin is distinct from 'johku';
  if v_own then
    select coalesce(sum(u.remaining) filter (where abs(coalesce(u.vat_rate, 0) - 25.5) < 0.001 and u.remaining > 0.004), 0)
      into v_ok from booking._order_uncovered(o.id, false) u;
    if v_amt > v_ok + 0.004 then
      perform booking._err('gift_card_vat_rate', 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %');
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu lahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, gift_card_id, note, created_by)
  values (o.id, 'gift_card', 'manual', 'pending', v_amt, g.id, nullif(concat_ws(' | ', 'Lahjakortti …' || right(g.code, 4), p_note), ''), auth.uid()) returning id into v_id;
  if v_own then
    v_left := v_amt;
    if abs(v_ok - v_amt) < 0.005 then
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select v_id, u.item_id, u.description, u.kind, u.quantity, u.remaining, u.vat_rate
        from booking._order_uncovered(o.id, false) u
       where abs(coalesce(u.vat_rate, 0) - 25.5) < 0.001 and u.remaining > 0.004;
    else
      for ur in select * from booking._order_uncovered(o.id, false) u where abs(coalesce(u.vat_rate, 0) - 25.5) < 0.001 and u.remaining > 0.004 loop
        exit when v_left <= 0.004;
        v_use := least(ur.remaining, v_left);
        insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
        values (v_id, ur.item_id, ur.description, ur.kind, case when v_use = ur.remaining then ur.quantity else 1 end, v_use, ur.vat_rate);
        v_left := v_left - v_use;
      end loop;
    end if;
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: tiedoksi-kuitti vain maksetulle omalle at_sale-kortille, ei kirjanpitoon
  perform booking._gc_apply(g.id, -v_amt, 'redemption', o.id, v_id, p_note);
  select * into v_card from booking.gift_cards where id = g.id;
  if v_card.single_order and v_card.balance > 0 then
    perform booking._gc_apply(g.id, -v_card.balance, 'single_order_forfeit', o.id, v_id, 'Kertakäyttökortti: jäännös ei käytettävissä');
    select * into v_card from booking.gift_cards where id = g.id;
  end if;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  v_rest := greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0);
  if o.status = 'pending' and v_rest <= 0.004 then
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
    v_confirmed := true;
  end if;
  v_excl := booking._acct_excluded(o.id, v_id);
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'amount', v_amt, 'order_id', o.id, 'balance', booking._order_balance(o.id),
    'gift_card', jsonb_build_object('id', v_card.id, 'code_last4', right(v_card.code, 4), 'balance', v_card.balance, 'status', v_card.status, 'valid_to', v_card.valid_to),
    'receipt_id', rc.id, 'receipt_no', rc.receipt_no, 'accounted', not v_excl,
    'confirmed', v_confirmed, 'remaining', v_rest, 'order_status', (select status from booking.orders where id = o.id));
end $function$;

CREATE OR REPLACE FUNCTION booking.mobilepay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid, p_expires_minutes integer DEFAULT 120, p_user_flow text DEFAULT 'WEB_REDIRECT'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._mobilepay_mode(); o booking.orders; pay booking.payments; v_tot numeric; v_unpaid numeric; v_open booking.payments;
  v_super jsonb := '[]'::jsonb; v_raw jsonb; v_mp jsonb; v_att int; v_ref text; v_id bigint; v_exp timestamptz; r record; v_started timestamptz;
  v_flow text; v_mins integer;
begin
  if v_mode = 'off' then perform booking._err('mobilepay_off', 'MobilePay-verkkomaksu ei ole käytössä'); end if;
  if (p_order_token is null) = (p_link_token is null) then perform booking._err('invalid_param', 'Anna joko p_order_token tai p_link_token'); end if;
  if p_expires_minutes is null or p_expires_minutes < 15 or p_expires_minutes > 1440 then perform booking._err('invalid_param', 'Voimassaolo 15–1440 min'); end if;
  v_flow := upper(btrim(coalesce(p_user_flow, 'WEB_REDIRECT')));
  if v_flow not in ('WEB_REDIRECT', 'QR', 'PUSH_MESSAGE') then perform booking._err('invalid_param', 'userFlow: WEB_REDIRECT, QR tai PUSH_MESSAGE'); end if;
  v_mins := p_expires_minutes;
  if v_flow in ('QR', 'PUSH_MESSAGE') and v_mins > 20 then v_mins := 20; end if;
  if not booking._rate_limit('mpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then perform booking._err('rate_limited', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then perform booking._err('not_found', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  end if;
  if o.external_source is not null then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;       -- Johku-eristys
  if booking._order_invoice_locked(o.id) or o.payment_status = 'invoiced' then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;
  if o.status not in ('pending', 'confirmed', 'completed', 'expired') then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;
  if o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_not_payable', 'Alustavaa varausta ei makseta ennen vahvistusta'); end if;
  if v_flow = 'PUSH_MESSAGE' and o.source_channel is distinct from 'pikakassa' then
    perform booking._err('push_not_allowed', 'Mobiilimaksupyyntö on vain pikakassan tilauksille');
  end if;
  if o.currency <> 'EUR' then perform booking._err('unsupported_currency', 'Vain EUR tuettu'); end if;
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;

  if p_link_token is not null then
    if pay.status = 'paid' then perform booking._err('already_paid', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then perform booking._err('payment_not_pending', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider not in ('visma_pay', 'mobilepay') then perform booking._err('payment_not_online', 'Ei verkkomaksu'); end if;
    if pay.provider = 'visma_pay' and pay.provider_ref is not null then perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla'); end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then perform booking._err('link_expired', 'Maksulinkki on vanhentunut'); end if;
    if pay.amount > v_unpaid + 0.004 then perform booking._err('link_stale', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta – pyydä uusi linkki'); end if;
    if pay.provider = 'visma_pay' then   -- asiakas valitsi MobilePayn maksulinkin sivulla: siirretään maksu MobilePaylle
      update booking.payments set provider = 'mobilepay', method = 'mobilepay', note = concat_ws(' | ', note, 'vaihdettu MobilePaylle') where id = pay.id returning * into pay;
    end if;
  else
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then perform booking._err('already_paid', 'Tilaus on jo maksettu'); end if;
      perform booking._err('nothing_to_pay', 'Ei maksettavaa');
    end if;
    if exists (select 1 from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and provider_ref is not null and (link_expires_at is null or link_expires_at > now())) then
      perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'mobilepay' and (link_expires_at is null or link_expires_at > now()) and amount = v_tot
      order by id desc limit 1 for update;
    if found then
      pay := v_open;
    else
      for r in select id, provider_ref, raw from booking.payments where order_id = o.id and status = 'pending' and provider in ('mobilepay', 'visma_pay') for update loop
        if r.provider_ref is not null and coalesce(r.raw -> 'mobilepay' ->> 'last_state', 'CREATED') = 'CREATED' then
          v_super := v_super || jsonb_build_array(r.provider_ref);
        end if;
        update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella MobilePay-maksulla') where id = r.id;
      end loop;
      v_exp := now() + make_interval(mins => v_mins);
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'mobilepay', 'mobilepay', 'pending', v_tot, o.currency, v_exp, 'MobilePay-verkkomaksu') returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
    end if;
  end if;

  perform booking._checkout_extend_hold(o.id);    -- booking_53: MobilePay-maksu alkaa -> paikka pysyy varattuna lopputulokseen asti (katto: checkout_mobilepay_max_wait_minutes)
  v_raw := coalesce(pay.raw, '{}'::jsonb); v_mp := coalesce(v_raw -> 'mobilepay', '{}'::jsonb);
  v_started := nullif(v_mp ->> 'attempt_started_at', '')::timestamptz;
  -- sama yritys vielä kesken (alle 8 min, sama user_flow, Vipps-maksu luotu, ei lopputilaa): käytetään samaa ohjausosoitetta
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' and v_started is not null and v_started > now() - interval '8 minutes'
     and coalesce(v_mp ->> 'user_flow', 'WEB_REDIRECT') = v_flow
     and (v_flow = 'PUSH_MESSAGE' or pay.link_url is not null) then
    return jsonb_build_object('ok', true, 'reuse', true, 'payment_id', pay.id, 'reference', pay.provider_ref, 'redirect_url', pay.link_url,
      'user_flow', v_flow, 'pushed', v_flow = 'PUSH_MESSAGE', 'order_no', o.order_no, 'order_token', o.public_token, 'mode', v_mode);
  end if;
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' then
    v_super := v_super || jsonb_build_array(pay.provider_ref);   -- edellinen keskeneräinen yritys perutaan Vippsissä
  end if;
  v_att := coalesce((v_mp ->> 'attempts')::int, 0) + 1;
  v_ref := 'sauna-o' || o.order_no || '-p' || pay.id || '-a' || v_att;
  v_mp := v_mp || jsonb_build_object('attempts', v_att, 'attempt_started_at', now(), 'last_state', null, 'env', v_mode, 'user_flow', v_flow,
                                     'refs', coalesce(v_mp -> 'refs', '[]'::jsonb) || to_jsonb(v_ref));
  update booking.payments set provider_ref = v_ref, provider_status = 'initiating', link_url = null,
         -- booking_184: 20 min katkaisu vain verkkokaupan maksulle, ei maksulinkille (takarajaton tai voimassaolo yli 2 h)
         link_expires_at = case when p_link_token is null and v_flow in ('QR', 'PUSH_MESSAGE')
                                     and not coalesce((pay.link_expires_at is null and coalesce(pay.raw ->> 'paylink', '') = 'no_deadline')
                                                      or pay.link_expires_at - pay.created_at > interval '2 hours', false)
                                then least(coalesce(link_expires_at, now() + interval '20 minutes'), now() + interval '20 minutes') else link_expires_at end,
         raw = jsonb_set(v_raw, '{mobilepay}', v_mp, true) where id = pay.id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'reuse', false, 'payment_id', pay.id, 'reference', v_ref, 'attempt', v_att, 'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint,
    'currency', pay.currency, 'order_id', o.id, 'order_no', o.order_no, 'order_token', o.public_token, 'locale', o.locale, 'mode', v_mode, 'user_flow', v_flow, 'superseded', v_super,
    'description', left('Sipoonjoen Perinnesauna – tilaus ' || o.order_no, 100),
    'site_base_url', booking._setting('site_base_url', null) #>> '{}', 'order_page_path', booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}');
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_get_order(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; c booking.customers; v_end timestamptz; v_site text; v_op text; v_pp text;
  v_locked boolean; v_unpaid numeric; v_inv text;
begin
  perform booking._require_staff();
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_site := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
  v_pp := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/');
  v_locked := booking._order_invoice_locked(o.id);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  select i.invoice_no into v_inv from booking.invoices i
   where i.order_id = o.id and i.kind = 'debit' and i.status in ('sent','paid','overdue','credited')
   order by i.id desc limit 1;
  return jsonb_build_object(
    'order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross,
    'source_channel', o.source_channel, 'created_at', o.created_at, 'customer_note', o.customer_note, 'internal_note', o.internal_note,
    'customer_kind', o.customer_kind, 'billing', o.billing, 'invoice_reference', o.invoice_reference,
    'customer', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
        'company', c.company, 'customer_kind', c.customer_kind, 'business_id', c.business_id) end,
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'product_name', it.product_name, 'mode', r.mode,
        'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'notes', r.notes, 'item_total', it.line_total_gross, 'item_id', r.order_item_id,
        'product_id', r.product_id, 'option', booking._option_json(r.product_option_id), 'option_choices', booking._product_options_json(r.product_id),
        'option_missing', (r.product_option_id is null and exists (select 1 from booking.product_options x where x.product_id = r.product_id and x.active)),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity,
                     'unit_price', ai.unit_price_gross, 'line_total', ai.line_total_gross, 'vat_rate', ai.vat_rate) order by ai.id)
                   from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb)) order by r.starts_at)
        from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null), '[]'::jsonb),
    'public_token', o.public_token, 'order_page_path', v_site || v_op || '?t=' || o.public_token, 'is_native', o.external_source is null,
    'balance', booking._order_balance(o.id),
    'invoice_locked', v_locked, 'invoice_no', v_inv,
    'can_add', o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not v_locked, 'add_until', v_end,
    'staff_can_add', o.external_source is null and o.status in ('confirmed','completed') and not v_locked,
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'parent_item_id', i.parent_item_id, 'kind', i.kind, 'product_id', i.product_id, 'name', i.product_name,
        'quantity', i.quantity, 'unit_price', i.unit_price_gross, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'line_vat', i.line_vat, 'line_net', i.line_net,
        'covered', cv.cov, 'remaining', i.line_total_gross - cv.cov) order by i.id)
        from booking.order_items i
        left join lateral (select coalesce(sum(pl.amount_gross - pl.refunded_gross), 0) cov from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                            where pl.order_item_id = i.id and p.status in ('paid','partially_refunded','refunded')) cv on true
       where i.order_id = o.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'status', p.status, 'amount', p.amount, 'paid_at', p.paid_at,
        'provider', p.provider, 'provider_status', p.provider_status, 'refunded_amount', p.refunded_amount, 'rounding', p.rounding, 'link_token', p.link_token,
        'link_path', case when p.provider <> 'manual' and p.status = 'pending' then v_pp || '?p=' || p.link_token end, 'link_expires_at', p.link_expires_at,
        'link_stale', case when p.status = 'pending' and p.provider <> 'manual' and p.link_token is not null then p.amount > v_unpaid + 0.004 else false end,
        'note', p.note, 'created_at', p.created_at,
        'lines', coalesce((select jsonb_agg(jsonb_build_object('id', pl.id, 'order_item_id', pl.order_item_id, 'description', pl.description, 'quantity', pl.quantity,
                      'amount_gross', pl.amount_gross, 'vat_rate', pl.vat_rate, 'net', pl.line_net, 'vat_eur', pl.amount_gross - pl.line_net, 'refunded_gross', pl.refunded_gross) order by pl.id)
                    from booking.payment_lines pl where pl.payment_id = p.id), '[]'::jsonb),
        'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'issued_at', rc.issued_at,
                      'public_token', rc.public_token, 'sent_at', rc.sent_at) order by rc.id) from booking.receipts rc where rc.payment_id = p.id), '[]'::jsonb),
        'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'amount', f.amount, 'status', f.status, 'reason', f.reason, 'created_at', f.created_at,
                      'done_at', f.done_at) order by f.id) from booking.refunds f where f.payment_id = p.id), '[]'::jsonb)) order by p.id)
        from booking.payments p where p.order_id = o.id), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'issued_at', rc.issued_at, 'total', rc.total_gross,
        'payment_id', rc.payment_id, 'refund_id', rc.refund_id, 'public_token', rc.public_token, 'sent_at', rc.sent_at) order by rc.id)
        from booking.receipts rc where rc.order_id = o.id), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'payment_id', f.payment_id, 'amount', f.amount, 'status', f.status, 'reason', f.reason,
        'created_at', f.created_at, 'done_at', f.done_at) order by f.id) from booking.refunds f where f.order_id = o.id), '[]'::jsonb),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'sent_at', e.sent_at, 'created_at', e.created_at) order by e.id)
        from booking.email_outbox e where e.order_id = o.id), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'status', q.status, 'reason', q.reason, 'created_at', q.created_at,
        'handled_at', q.handled_at, 'note', q.note) order by q.id) from booking.order_requests q where q.order_id = o.id), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
  v_cancel_dl timestamptz; v_cancel_closed boolean;   -- booking_149: asiakkaan peruutuspyynnön takaraja
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and exists (select 1 from booking.reservations r where r.order_id = o.id) and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._vismapay_online();
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at, 'method_label', coalesce(pm.label, p.method),
           'link_token', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not booking._order_invoice_locked(o.id);
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  -- booking_149: asiakas voi pyytää peruutusta (ja sen hyvitystä) vain, kun ensimmäisen voimassa olevan vuoron alkuun on vähintään customer_change_hours_before tuntia (oletus 48).
  v_cancel_dl := booking._customer_cancel_deadline(o.id);
  v_cancel_closed := v_open and (v_cancel_dl is null or v_cancel_dl < now());
  v_open := v_open and v_cancel_dl is not null and v_cancel_dl >= now();
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'invoice_locked', booking._order_invoice_locked(o.id),
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq,
    'cancel_deadline', v_cancel_dl, 'cancel_hours_before', v_hours, 'cancel_closed', coalesce(v_cancel_closed, false), 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)),
    'instructions', booking._order_full_instructions(o.id, coalesce(o.locale, 'fi')))
    || booking._checkout_state_json(o.id);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_upsell_for_order(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_start timestamptz; v_origins bigint[]; v_date date; v_options jsonb; v_addons jsonb;
begin
  if p_token is null or not booking._order_rl('upsell', p_token, 30, 12) then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found or o.external_source is not null or o.status <> 'confirmed' then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  if booking._order_invoice_locked(o.id) then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  select min(starts_at), array_agg(distinct product_id) into v_start, v_origins from booking.reservations
   where order_id = o.id and booking._res_active(status, hold_expires_at);
  if v_start is null or v_start <= now() + make_interval(mins => booking._upsell_cutoff()) then return jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb); end if;
  v_date := (v_start at time zone booking._tz())::date;
  v_options := booking._upsell_options(v_origins, v_origins, v_date, 1, 9);
  select coalesce(jsonb_agg(a.value), '[]'::jsonb) into v_addons from jsonb_array_elements(v_options->'addons') a
   where not exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.addon_id = (a.value->>'addon_id')::bigint)
     and exists (select 1 from booking.reservations r where r.order_id = o.id and r.product_id = (a.value->>'origin')::bigint and booking._res_active(r.status, r.hold_expires_at));
  return jsonb_set(v_options, '{addons}', v_addons);
end $f$;

create or replace function booking.admin_set_reservation_addons(p_reservation_id bigint, p_addons jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  res booking.reservations;
  a booking.addons;
  e jsonb;
  l record;
  v_old jsonb;
  v_total numeric;
  v_locked jsonb := '[]'::jsonb;
  v_added jsonb := '[]'::jsonb;
  v_acc jsonb := '{}'::jsonb;
  v_extra jsonb := '{}'::jsonb;
  v_lockq jsonb := '{}'::jsonb;
  v_rituals jsonb := '[]'::jsonb;
  v_attach jsonb;
  v_idtxt text;
  v_code text;
  v_key text;
  v_qty integer;
  v_lim integer;
  v_kept_ids bigint[] := '{}'::bigint[];
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if res.status not in ('pending','confirmed') then perform booking._err('not_editable', 'Lisäpalveluita voi muuttaa vain voimassa olevaan varaukseen'); end if;

  -- booking_180: sama tilauslukko kuin maksulinkin luonnissa, käsimaksussa ja hyvityksessä; alla olevat lauseet näkevät niiden commitoidut rivit.
  perform 1 from booking.orders where id = res.order_id for update;
  if booking._order_invoice_locked(res.order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', product_name, 'quantity', quantity) order by id), '[]'::jsonb)
    into v_old from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';

  -- Lukittu rivi: maksetuissa maksuissa nettokatetta (amount_gross - refunded_gross > 0) tai avoin verkkomaksulinkki.
  -- Kokonaan hyvitetty rivi ei ole lukittu (vanha käytös: rivin voi poistaa, tilauksen summa laskee hyvitetyn verran).
  for l in
    select i.id, i.addon_id, i.quantity,
      coalesce((select sum(pl.amount_gross - pl.refunded_gross) from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                 where pl.order_item_id = i.id and p.status in ('paid','partially_refunded','refunded')), 0) > 0.004 as has_paid,
      exists (select 1 from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
               where pl.order_item_id = i.id and p.status = 'pending' and p.provider <> 'manual') as has_link
    from booking.order_items i
    where i.parent_item_id = res.order_item_id and i.kind = 'addon'
    order by i.id for update of i
  loop
    continue when not l.has_paid and not l.has_link;
    v_locked := v_locked || jsonb_build_array(jsonb_build_object('item_id', l.id, 'addon_id', l.addon_id,
                      'quantity', l.quantity, 'paid', l.has_paid, 'link_open', l.has_link));
  end loop;

  if jsonb_array_length(v_locked) = 0 then
    -- Ei lukittuja rivejä: täsmälleen vanha polku (kaikki rivit pois, syöte sellaisenaan _attach_addons-funktiolle).
    v_attach := p_addons;
  else
    -- Normalisoi pyydetty kokonaismäärä per lisäpalvelu; ritual_start-elementit sellaisenaan.
    if p_addons is not null and p_addons <> 'null'::jsonb then
      if jsonb_typeof(p_addons) <> 'array' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
      if jsonb_array_length(p_addons) > 20 then perform booking._err('invalid_addons', 'Liian monta lisäpalvelua'); end if;
      for e in select x from pg_catalog.jsonb_array_elements(p_addons) x loop
        if jsonb_typeof(e) = 'object' and e ? 'ritual_start' then v_rituals := v_rituals || jsonb_build_array(e); continue; end if;
        if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
        v_idtxt := e ->> 'id'; v_code := e ->> 'code';
        if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
        v_qty := (e ->> 'quantity')::integer;
        if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
        select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
        if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
        v_acc := jsonb_set(v_acc, array[a.id::text], to_jsonb(coalesce((v_acc ->> a.id::text)::integer, 0) + v_qty));
      end loop;
    end if;
    v_extra := v_acc;

    -- Vähennys lukitun määrän alle hylätään ennen yhtään muutosta.
    for l in
      select x.addon_id, sum(x.quantity)::integer as quantity, bool_or(x.link_open) as link_open
        from pg_catalog.jsonb_to_recordset(v_locked) as x(item_id bigint, addon_id bigint, quantity integer, paid boolean, link_open boolean)
       group by x.addon_id order by x.addon_id
    loop
      v_qty := coalesce((v_acc ->> l.addon_id::text)::integer, 0);
      if v_qty < l.quantity then
        if l.link_open then perform booking._err('addon_link_open', 'Lisäpalvelu on avoimella maksulinkillä. Odota maksua tai linkin vanhenemista.'); end if;
        perform booking._err('addon_paid', 'Lisäpalvelu on jo maksettu. Hyvitä se ensin tilausnäkymässä.');
      end if;
      v_lockq := jsonb_set(v_lockq, array[l.addon_id::text], to_jsonb(l.quantity));
      v_extra := jsonb_set(v_extra, array[l.addon_id::text], to_jsonb(v_qty - l.quantity));
    end loop;

    -- Enimmäismäärä koskee pyydettyä kokonaismäärää. Jo lukittu määrä kelpaa aina, vaikka henkilömäärä
    -- tai max_per_person olisi myöhemmin laskenut (muuten varausta ei voisi tallentaa eikä vähentää).
    for v_key, v_qty in select k, (v_acc ->> k)::integer from pg_catalog.jsonb_object_keys(v_acc) k order by k::bigint loop
      select * into a from booking.addons where id = v_key::bigint;
      v_lim := booking._addon_limit(a.max_per_person, res.persons);
      if v_qty > greatest(v_lim, coalesce((v_lockq ->> v_key)::integer, 0)) then
        perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi valita enintään %s kpl', a.name, greatest(v_lim, coalesce((v_lockq ->> v_key)::integer, 0))));
      end if;
    end loop;

    -- Lukitut rivit säilyvät; liitetään vain positiiviset erotukset (ja ritual_start-elementit).
    v_attach := v_rituals;
    for v_key, v_qty in select k, (v_extra ->> k)::integer from pg_catalog.jsonb_object_keys(v_extra) k order by k::bigint loop
      if v_qty > 0 then v_attach := v_attach || jsonb_build_array(jsonb_build_object('id', v_key::bigint, 'quantity', v_qty)); end if;
    end loop;
  end if;

  delete from booking.order_items i
   where i.parent_item_id = res.order_item_id and i.kind = 'addon'
     and not (i.id = any (select (x ->> 'item_id')::bigint from pg_catalog.jsonb_array_elements(v_locked) x));
  select coalesce(array_agg(i.id), '{}'::bigint[]) into v_kept_ids from booking.order_items i
   where i.parent_item_id = res.order_item_id and i.kind = 'addon';
  update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = res.order_id), 0) where id = res.order_id;
  perform booking._attach_addons(res.id, v_attach);
  select coalesce(jsonb_agg(jsonb_build_object('item_id', i.id, 'addon_id', i.addon_id, 'quantity', i.quantity) order by i.id), '[]'::jsonb)
    into v_added from booking.order_items i where i.parent_item_id = res.order_item_id and i.kind = 'addon' and not i.id = any (v_kept_ids);
  select total_gross into v_total from booking.orders where id = res.order_id;
  if v_total < (select coalesce(sum(p.amount), 0) - coalesce(sum(p.refunded_amount), 0) from booking.payments p
                 where p.order_id = res.order_id and p.status in ('paid','partially_refunded','refunded')) then
    perform booking._err('below_paid', 'Tilauksen summa ei voi laskea alle maksetun summan (hyvitä ensin)');
  end if;
  perform booking._sync_placeholder(res.order_id);
  perform booking._refresh_order_payment(res.order_id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'order_items', res.order_id::text, 'ADMIN_SET_ADDONS', jsonb_build_object('addons', v_old),
          jsonb_build_object('addons', coalesce(p_addons, '[]'::jsonb), 'total', v_total)
          || case when jsonb_array_length(v_locked) > 0 then jsonb_build_object('locked', v_locked, 'added', v_added) else '{}'::jsonb end);
  return jsonb_build_object('ok', true, 'total', v_total);
end $function$;

CREATE OR REPLACE FUNCTION booking._vc_pay(o booking.orders, c booking.voucher_claims, p_value numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_unpaid numeric; v_amt numeric; v_id bigint; v_it record; v_note text; v_method text;
begin
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if p_value is not null and (p_value < 0 or p_value <> round(p_value, 2)) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if c.order_item_id is not null then
    select * into v_it from booking._order_uncovered(o.id, false) u where u.item_id = c.order_item_id;
    v_unpaid := least(v_unpaid, coalesce(v_it.remaining, 0));
  end if;
  v_amt := least(coalesce(p_value, v_unpaid), v_unpaid);
  if v_amt <= 0 then return jsonb_build_object('payment_id', null, 'amount', 0); end if;
  v_method := booking._vc_method(c.source);
  v_note := concat_ws(' | ', coalesce((select pm.label from booking.payment_methods pm where pm.code = v_method), 'Kumppanin lahjakortti (' || booking._vc_source_label(c.source) || ')') || ' ' || booking._vc_mask(c.code), 'pyyntö #' || c.id, c.partner_ref);
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu kumppanilahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, note, created_by)
  values (o.id, v_method, 'manual', 'pending', v_amt, v_note, auth.uid()) returning id into v_id;
  if c.order_item_id is not null then
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    values (v_id, v_it.item_id, v_it.description, v_it.kind, case when v_amt = v_it.remaining then v_it.quantity else 1 end, v_amt, v_it.vat_rate);
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;      -- _acct_excluded: ei kuittia / kassaraporttia (oletus)
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  return jsonb_build_object('payment_id', v_id, 'amount', v_amt);
end $function$;

CREATE OR REPLACE FUNCTION booking._attach_addons(p_reservation_id bigint, p_addons jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.reservations; a booking.addons; e jsonb; v_acc jsonb := '{}'::jsonb; v_key text; v_qty integer; v_total numeric := 0;
  v_idtxt text; v_code text; v_lim integer; v_mode text; v_rit jsonb; v_rn integer := 0;
begin
  if p_addons is null or p_addons = 'null'::jsonb then return 0; end if;
  if jsonb_typeof(p_addons) <> 'array' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
  if jsonb_array_length(p_addons) = 0 then return 0; end if;
  if jsonb_array_length(p_addons) > 20 then perform booking._err('invalid_addons', 'Liian monta lisäpalvelua'); end if;
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if booking._order_invoice_locked(r.order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;

  -- tehokas tila: yleinen vuoro / yksityisvuoro = r.mode (shared / exclusive); resurssivaraus (hoito, saunotus, rituaali; sale_kind 'other') = 'resource';
  -- tapahtuma (kb.products.category = 'event') = 'event' (ei lisäpalveluita)
  select case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end
    into v_mode from booking.product_config pc join kb.products p on p.id = pc.product_id where pc.product_id = r.product_id;
  v_mode := coalesce(v_mode, r.mode);

  -- booking_166: saunarituaali-elementti {"ritual_start": ISO-aika aikavyöhykkeineen, "quantity": henkilöt} käsitellään erikseen
  -- (oma varaus rituaaliresurssille samaan tilaukseen, hinta palvelimella; booking._ritual_addon_attach). Enintään yksi.
  for e in select x from jsonb_array_elements(p_addons) x where jsonb_typeof(x) = 'object' and x ? 'ritual_start' loop
    v_rn := v_rn + 1; v_rit := e;
  end loop;
  if v_rn > 1 then perform booking._err('ritual_addon_invalid', 'Saunarituaalin voi valita vain kerran'); end if;
  if v_rn = 1 then v_total := v_total + booking._ritual_addon_attach(r.id, v_rit); end if;

  for e in select x from jsonb_array_elements(p_addons) x where not (jsonb_typeof(x) = 'object' and x ? 'ritual_start') loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
    v_idtxt := e ->> 'id'; v_code := e ->> 'code';
    if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
    v_qty := (e ->> 'quantity')::int;
    if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
    if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    v_acc := jsonb_set(v_acc, array[a.id::text], to_jsonb(coalesce((v_acc ->> a.id::text)::int, 0) + v_qty));
  end loop;

  for v_key, v_qty in select k, (v_acc ->> k)::int from jsonb_object_keys(v_acc) k order by k::bigint loop
    continue when v_qty = 0;
    select * into a from booking.addons where id = v_key::bigint;
    if not a.active then perform booking._err('addon_inactive', format('Lisäpalvelu "%s" ei ole käytössä', a.name)); end if;
    if not (v_mode = any (a.applies_modes)) then perform booking._err('addon_not_allowed', format('Lisäpalvelu "%s" ei ole saatavilla tälle vuorolle', a.name)); end if;
    v_lim := booking._addon_limit(a.max_per_person, r.persons);
    if v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi valita enintään %s kpl', a.name, v_lim)); end if;
    insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, addon_id, parent_item_id, price_breakdown)
    values (r.order_id, a.name, 'addon', v_qty, a.price_gross, a.price_gross * v_qty, a.vat_rate, a.id, r.order_item_id,
            jsonb_build_object('addon_code', a.code, 'name_en', a.name_en, 'unit_price', a.price_gross, 'quantity', v_qty, 'max_per_person', a.max_per_person));
    v_total := v_total + a.price_gross * v_qty;
  end loop;
  if v_total > 0 then update booking.orders set total_gross = total_gross + v_total where id = r.order_id; end if;
  return v_total;
end $function$;

create or replace function booking._ritual_addon_attach(p_res_id bigint, p_el jsonb)
 returns numeric
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c jsonb := booking._ritual_addon_cfg(); r booking.reservations; v_prod bigint; p kb.products; pc booking.product_config;
  v_txt text; v_start timestamptz; v_end timestamptz; v_q int; v_max int; v_st text; v_price numeric; v_item bigint; v_child booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_missing boolean := false; v_ecode text;
  v_off int; v_cmin int; v_pools bigint[];
begin
  select * into r from booking.reservations where id = p_res_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if booking._order_invoice_locked(r.order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  v_prod := nullif(c ->> 'product_id', '')::bigint;
  if not coalesce((c ->> 'enabled')::boolean, false) or v_prod is null then
    perform booking._err('ritual_addon_unavailable', 'Saunarituaali ei ole nyt varattavissa');
  end if;
  if r.rule_id is null or r.mode <> 'shared' or not booking._ritual_addon_session_ok(r.rule_id) then
    perform booking._err('ritual_addon_not_allowed', 'Saunarituaalin voi lisätä vain yleiselle vuorolle');
  end if;
  select * into p from kb.products where id = v_prod and active;
  select * into pc from booking.product_config where product_id = v_prod;
  if p.id is null or pc.product_id is null then perform booking._err('ritual_addon_unavailable', 'Saunarituaali ei ole nyt varattavissa'); end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_txt := btrim(coalesce(p_el ->> 'ritual_start', ''));
  -- aika aina aikavyöhykkeen kanssa (tuotannon istunto on UTC): '…Z' tai '…+02:00' / '+0200' / '+02'
  if v_txt !~ '^\d{4}-\d\d-\d\d[T ]\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d(:?\d\d)?)$' then
    perform booking._err('ritual_addon_time', 'Saunarituaalin aika on virheellinen');
  end if;
  begin v_start := v_txt::timestamptz;
  exception when others then perform booking._err('ritual_addon_time', 'Saunarituaalin aika on virheellinen');
  end;
  v_max := least(r.persons, booking._treatment_max_persons(v_prod));
  if coalesce(p_el ->> 'quantity', '') !~ '^\d{1,3}$' or (p_el ->> 'quantity')::int < greatest(coalesce(pc.min_persons, 1), 1) or (p_el ->> 'quantity')::int > v_max then
    perform booking._err('ritual_addon_persons', format('Saunarituaaliin voi valita 1–%s henkilöä', greatest(v_max, 1)));
  end if;
  v_q := (p_el ->> 'quantity')::int;
  if not exists (select 1 from booking._ritual_addon_starts(r.starts_at, r.ends_at) t where t = v_start) then
    perform booking._err('ritual_addon_time', 'Saunarituaalin aika ei sovi valitulle vuorolle');
  end if;
  v_st := booking._ritual_addon_fit(v_start, v_q, true);
  if v_st is null then
    perform booking._err('ritual_addon_full', 'Valittu saunarituaalin aika ei ole enää vapaana – valitse toinen aika');
  end if;
  v_end := v_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes));

  begin
    for lp in select * from booking._plan_legs(v_prod, v_start, v_end, v_q) loop v_plan := array_append(v_plan, lp); end loop;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_ecode = pg_exception_detail;
    if v_ecode is distinct from 'no_therapist' then perform booking._err('ritual_addon_full', 'Valittu saunarituaalin aika ei ole enää vapaana – valitse toinen aika'); end if;
    v_plan := '{}'; v_missing := true;
    for lp in select * from booking._plan_legs(v_prod, v_start, v_end, v_q, null, false, null, true) loop v_plan := array_append(v_plan, lp); end loop;
  end;
  select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
  if v_prim.resource_id is null then perform booking._err('no_primary_leg', 'Tuotteelta puuttuu ensisijainen tila (product_space_rules leg 1)'); end if;
  v_off := (extract(epoch from (v_prim.claim_start - v_start)) / 60)::int;
  v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
  v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;

  v_price := round(booking._treatment_price(v_prod, v_q), 2);   -- palvelimen hinta (kb.products), asiakkaan lähettämää hintaa ei käytetä
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (r.order_id, p.id, p.name, 'reservation', 1, v_price, v_price, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', v_q, 'ritual_addon', true, 'parent_reservation_id', r.id,
                             'unit_price', round(booking._treatment_price(v_prod, 1), 2), 'name_en', p.name_en))
  returning id into v_item;
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status, hold_expires_at,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, created_by, therapist_missing)
  values (r.order_id, v_item, p.id, v_prim.resource_id, v_prim.mode, v_start, v_end, v_q, v_pools, r.status, r.hold_expires_at,
          false, v_off, v_cmin, r.id, r.created_by, v_missing)
  returning * into v_child;                                  -- triggerit: kapasiteetti (reservations_validate) + aikaikkuna (poikkeus yllä)
  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key, quota_exempt, rule_id)
    values (v_child.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key, false, lp.rule_id);
  end loop;
  return v_price;
end $function$;

CREATE OR REPLACE FUNCTION booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_quota_exempt boolean, p_parent_reservation_id bigint, p_order_id bigint DEFAULT NULL::bigint, p_option_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_hmin int := coalesce(nullif(current_setting('booking.checkout_hold_minutes', true), '')::int, 0); v_hold timestamptz; v_st text := 'confirmed'; v_hkind text := nullif(current_setting('booking.checkout_hold_kind', true), '');
  p kb.products; pc booking.product_config; v_end timestamptz; v_total numeric; v_order booking.orders; v_item bigint; v_res booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_parent bigint; v_pools bigint[]; v_off integer; v_cmin integer; v_n integer := 0; v_missing boolean := false; v_ecode text; v_opt bigint;
begin
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('product_not_found', 'Tuotetta ei löydy'); end if;
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  if p_lifecycle is not null and pc.lifecycle <> p_lifecycle then
    perform booking._err('wrong_lifecycle', case p_lifecycle when 'old' then 'Valitse vanha tuote (current-tuotteet: Uusi varaus)' else 'Valitse nykyinen tuote' end);
  end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_opt := booking._resolve_product_option(p_product_id, p_option_code, true);     -- booking_50: tuotevalinta (pakollinen jos product_config.option_required ja aktiivisia vaihtoehtoja)
  v_end := coalesce(p_end, p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes)));
  if p_start is null or v_end is null or v_end <= p_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  if p_override and (p_override_reason is null or length(btrim(p_override_reason)) < 3) then perform booking._err('override_reason_required', 'Ylitys vaatii perustelun'); end if;

  -- lisäpalvelu (kb 27/28): vaatii kattavan vanhempivarauksen (jälkilöyly / oma vuoro)
  if cardinality(pc.requires_parent_product_ids) > 0 then
    select r.id into v_parent
      from booking.reservations r join booking.orders o on o.id = r.order_id
     where r.product_id = any (pc.requires_parent_product_ids) and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at <= p_start and r.ends_at >= v_end
       and (p_parent_reservation_id is null or r.id = p_parent_reservation_id)
     order by (o.customer_id is not distinct from p_customer_id) desc, r.starts_at limit 1;
    if v_parent is null and not p_override then
      perform booking._err('parent_required', 'Lisäpalvelu vaatii jälkilöyly-/yksityisvuorovarauksen samalle ajalle');
    end if;
  end if;

  begin
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override) loop v_plan := array_append(v_plan, lp); end loop;
  exception when sqlstate 'BK001' then
    -- booking_22: ei vapaata saunottajaa -> varaus syntyy ilman saunottajalegiä (therapist_missing), kaikki muut virheet nousevat ennallaan
    get stacked diagnostics v_ecode = pg_exception_detail;
    if v_ecode is distinct from 'no_therapist' then raise; end if;
    v_plan := '{}'; v_missing := true;
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override, null, true) loop v_plan := array_append(v_plan, lp); end loop;
  end;
  select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
  if v_prim.resource_id is null then perform booking._err('no_primary_leg', 'Tuotteelta puuttuu ensisijainen tila (product_space_rules leg 1)'); end if;
  v_off := (extract(epoch from (v_prim.claim_start - p_start)) / 60)::int;
  v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
  if v_prim.mode = 'exclusive' and (v_off <> 0 or v_cmin is not null) then perform booking._err('bad_rule', 'Yksinoikeusvarauksen claim-ikkuna on aina koko varaus'); end if;
  v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;

  v_total := coalesce(p_price, coalesce(p.price, 0) + coalesce(p.extra_person_price, 0) * greatest(p_persons - coalesce(p.included_persons, p_persons), 0));
  if p_order_id is null then
    -- booking_53: julkinen kassa voi pyytää pidon (GUC booking.checkout_hold_minutes): tilaus 'pending' + varaus 'pending' + hold_expires_at
    if v_hmin > 0 then v_st := 'pending'; v_hold := now() + make_interval(mins => v_hmin); end if;
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by, confirmed_at, hold_kind)
    values (p_customer_id, v_st, 'unpaid', v_total, p_channel, 'fi', p_note, p_created_by, case when v_st = 'confirmed' then now() end,
            case when v_st = 'pending' then coalesce(v_hkind, 'checkout') end) returning * into v_order;
  else   -- lisäys olemassa olevaan tilaukseen (booking_30): ei uutta tilausnumeroa
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if booking._order_invoice_locked(p_order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
    if v_order.status = 'pending' then    -- booking_53: odottavaan tilaukseen lisätty varaus seuraa tilauksen pitoa (ei jää ikuisesti auki)
      v_st := 'pending';
      v_hold := coalesce((select max(x.hold_expires_at) from booking.reservations x where x.order_id = p_order_id and x.status = 'pending' and x.hold_expires_at > now()),
                         now() + make_interval(mins => booking._checkout_hold_minutes()));
    end if;
  end if;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', p_persons)) returning id into v_item;

  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status, hold_expires_at,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, override_reason, created_by, therapist_missing, product_option_id)
  values (v_order.id, v_item, p.id, v_prim.resource_id, v_prim.mode, p_start, v_end, p_persons, v_pools, v_st, v_hold,
          p_quota_exempt, v_off, v_cmin, v_parent, case when p_override then btrim(p_override_reason) end, p_created_by, v_missing, v_opt)
  returning * into v_res;                                    -- trigger validoi ensisijaisen claimin

  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key,
                                         quota_exempt, override_reason, rule_id)
    values (v_res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key,
            p_quota_exempt, case when p_override then btrim(p_override_reason) end, lp.rule_id);   -- trigger validoi legin
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'reservation_id', v_res.id, 'total', v_total,
                            'starts_at', v_res.starts_at, 'ends_at', v_res.ends_at, 'legs', v_n, 'space_id', v_res.space_id,
                            'product_name', p.name, 'parent_reservation_id', v_parent, 'hold_expires_at', v_hold, 'res_status', v_st,
                            'therapist_missing', v_missing, 'warning', case when v_missing then 'therapist_missing' end,
                            'option', booking._option_json(v_opt));
end $function$;

CREATE OR REPLACE FUNCTION booking._create_booking_core(p_rule_id bigint, p_date date, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_locale text, p_note text, p_status text, p_hold_minutes integer, p_enforce_deadline boolean, p_override_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_override_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_price_override numeric DEFAULT NULL::numeric, p_annual_card_id bigint DEFAULT NULL::bigint, p_order_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rs record; p kb.products;
  pr record; v_total numeric; v_order booking.orders; v_item_id bigint; v_res_id bigint;
  v_hold timestamptz;
begin
  select * into rs from booking._resolve_session(p_rule_id, p_date, p_persons, p_enforce_deadline, p_override_start, p_override_end);
  select * into p from kb.products where id = rs.o_product_id;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;

  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_total := case when p_annual_card_id is not null then 0 else coalesce(p_price_override, pr.total) end;

  if p_order_id is null then
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by)
    values (p_customer_id, case when p_status = 'confirmed' then 'confirmed' else 'pending' end, 'unpaid', v_total,
            p_channel, coalesce(p_locale, 'fi'), p_note, p_created_by)
    returning * into v_order;
    if p_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;
  else   -- lisäys olemassa olevaan tilaukseen (booking_30)
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if booking._order_invoice_locked(p_order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
  end if;

  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          pr.breakdown || jsonb_build_object('rule_id', p_rule_id, 'rule_label', (select label from booking.schedule_rules where id = p_rule_id))
                       || case when p_annual_card_id is not null then jsonb_build_object('annual_card_id', p_annual_card_id) else '{}'::jsonb end)
  returning id into v_item_id;

  v_hold := case when p_status = 'pending' then now() + make_interval(mins => greatest(coalesce(p_hold_minutes, 15), 1)) end;
  -- Trigger reservations_validate lukitsee tilan ja tarkistaa päällekkäisyydet/kapasiteetin/vuosikortin; virhe kumoaa koko lisäyksen.
  insert into booking.reservations(order_id, order_item_id, product_id, rule_id, annual_card_id, space_id, mode, starts_at, ends_at, persons,
                                   pool_ids, status, hold_expires_at, created_by)
  values (v_order.id, v_item_id, p.id, p_rule_id, p_annual_card_id, rs.o_space_id, rs.o_mode, rs.o_starts_at, rs.o_ends_at, p_persons,
          rs.o_pool_ids, p_status, v_hold, p_created_by)
  returning id into v_res_id;

  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token,
                            'reservation_id', v_res_id, 'total', v_total, 'starts_at', rs.o_starts_at, 'ends_at', rs.o_ends_at,
                            'status', p_status, 'hold_expires_at', v_hold, 'product_name', p.name);
end $function$;

CREATE OR REPLACE FUNCTION booking._quiet_apply(p_order_id bigint, p_quiet jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_item booking.order_items; v_amt numeric; v_base numeric;
begin
  if p_quiet is null or p_order_id is null then return 0; end if;
  select * into v_item from booking.order_items where order_id = p_order_id and kind = 'reservation' order by id limit 1 for update;
  if v_item.id is null or coalesce(v_item.line_total_gross, 0) <= 0 then return 0; end if;
  -- booking_171: ale vain vuoron perushinnasta; lisähenkilöt (fixed_plus_extra) aina täyshintaisia
  v_base := booking._quiet_base(v_item.price_breakdown, v_item.line_total_gross);
  v_amt := least(v_base, round(v_base * (p_quiet ->> 'percent')::numeric / 100, 2));
  if v_amt <= 0 then return 0; end if;
  if booking._order_invoice_locked(p_order_id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = v_amt,
         price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('quiet', jsonb_build_object(
           'rule_id', (p_quiet ->> 'rule_id')::bigint, 'percent', (p_quiet ->> 'percent')::numeric, 'base', v_item.line_total_gross, 'discount_base', v_base,
           'amount', v_amt, 'hours_left', (p_quiet ->> 'hours_left')::numeric, 'source', 'quiet'))
   where id = v_item.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  return v_amt;
end $function$
;

CREATE OR REPLACE FUNCTION booking.vismapay_payment_prepare(p_order_token uuid default null, p_link_token uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_mode text := booking._vismapay_mode();
  o booking.orders; pay booking.payments; c booking.customers;
  v_tot numeric; v_unpaid numeric; v_att int; v_ref text; v_until bigint; v_reuse boolean := false;
  v_cust jsonb := null; v_first text; v_last text; v_email text;
begin
  if (p_order_token is null) = (p_link_token is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_param', 'message', 'Anna joko order_token tai link_token');
  end if;
  if not booking._rate_limit('vpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_mode = 'off' then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;

  if v_mode = 'dry_run' then
    if p_link_token is not null then
      return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
    end if;
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') or o.currency <> 'EUR' then
      return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa');
    end if;
    if booking._order_invoice_locked(o.id) or o.payment_status = 'invoiced' then
      return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa');
    end if;
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then
        return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Tilaus on jo maksettu');
      end if;
      return jsonb_build_object('ok', false, 'code', 'nothing_to_pay', 'message', 'Ei maksettavaa');
    end if;
    select * into pay from booking.payments
     where order_id = o.id and status = 'pending' and provider = 'visma_pay' and amount = v_tot and provider_ref like 'dryrun-%'
     order by id desc limit 1 for update;
    if not found then
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, now() + interval '30 minutes', 'Visma Pay dry_run, ei veloitusta')
      returning * into pay;
      update booking.payments set provider_ref = 'dryrun-' || pay.id, provider_status = 'dry_run' where id = pay.id returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
      perform booking._refresh_order_payment(o.id);
    end if;
    return jsonb_build_object('ok', true, 'mode', 'dry_run', 'dry_run', true, 'implemented', false,
      'payment_id', pay.id, 'provider_ref', pay.provider_ref, 'amount', pay.amount, 'currency', pay.currency,
      'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
      'message', 'Testitila: maksua ei veloiteta eikä kuittia synny.');
  end if;

  if v_mode not in ('test', 'live') then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
    if pay.status = 'paid' then return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then return jsonb_build_object('ok', false, 'code', 'payment_not_pending', 'message', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider = 'mobilepay' and pay.provider_ref is not null then
      return jsonb_build_object('ok', false, 'code', 'other_provider_started', 'message', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then
      return jsonb_build_object('ok', false, 'code', 'link_expired', 'message', 'Maksulinkki on vanhentunut');
    end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    if pay.amount > v_unpaid + 0.004 then
      return jsonb_build_object('ok', false, 'code', 'link_stale', 'message', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta');
    end if;
    v_tot := pay.amount;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then
        return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Tilaus on jo maksettu');
      end if;
      return jsonb_build_object('ok', false, 'code', 'nothing_to_pay', 'message', 'Ei maksettavaa');
    end if;
    select * into pay from booking.payments
     where order_id = o.id and status = 'pending' and provider = 'visma_pay' and amount = v_tot
       and coalesce(provider_ref, '') not like 'dryrun-%'
     order by (provider_ref is not null) desc, id desc
     limit 1 for update;
  end if;

  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or booking._order_invoice_locked(o.id) or o.customer_kind = 'company'
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa verkossa');
  end if;

  v_until := floor(extract(epoch from now() + interval '60 minutes'))::bigint;
  if pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'CREATED'
     and coalesce(pay.raw ->> 'redirect_url', '') <> ''
     and coalesce(pay.raw ->> 'token', '') <> ''
     and coalesce(pay.raw ->> 'token_valid_until', '') ~ '^\d+$'
     and (pay.raw ->> 'token_valid_until')::bigint > floor(extract(epoch from now()))::bigint
     and pay.provider_ref ~ '^sauna-[a-z0-9_-]+$' then
    v_reuse := true;
  elsif pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'initiating'
     and pay.updated_at > now() - interval '2 minutes' then
    return jsonb_build_object('ok', false, 'code', 'payment_in_progress', 'message', 'Maksun avaus on jo käynnissä. Odota hetki ja yritä uudelleen.');
  else
    if pay.id is null then
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, now() + interval '60 minutes', 'Visma Pay')
      returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
      v_att := 1;
    else
      v_att := coalesce((pay.raw ->> 'attempt')::int, 0) + 1;
      if v_att < 1 then v_att := 1; end if;
      if not exists (select 1 from booking.payment_lines where payment_id = pay.id) then
        insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
        select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      end if;
    end if;
    v_ref := 'sauna-o' || o.order_no::text || '-p' || pay.id::text || '-a' || v_att::text;
    update booking.payments
       set method = 'visma_pay', provider = 'visma_pay', provider_ref = v_ref, provider_status = 'initiating',
           raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('env', v_mode, 'attempt', v_att, 'last_state', 'initiating', 'token_valid_until', v_until::text)
     where id = pay.id
     returning * into pay;
    perform booking._refresh_order_payment(o.id);
  end if;

  if o.customer_id is not null then
    select * into c from booking.customers where id = o.customer_id;
    if found and c.anonymized_at is null then
      v_first := nullif(split_part(btrim(coalesce(c.name, '')), ' ', 1), '');
      v_last := nullif(btrim(substring(btrim(coalesce(c.name, '')) from char_length(split_part(btrim(coalesce(c.name, '')), ' ', 1)) + 1)), '');
      v_email := case when c.email is not null and booking._valid_email(c.email) then lower(btrim(c.email)) end;
      v_cust := jsonb_strip_nulls(jsonb_build_object(
        'firstname', v_first, 'lastname', v_last, 'email', v_email,
        'address_street', nullif(btrim(coalesce(c.address, '')), ''),
        'address_zip', nullif(btrim(coalesce(c.zip, '')), ''),
        'address_city', nullif(btrim(coalesce(c.city, '')), ''),
        'address_country', nullif(upper(btrim(coalesce(c.country, ''))), '')));
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'mode', v_mode, 'dry_run', false, 'implemented', true, 'reuse', v_reuse,
    'payment_id', pay.id, 'order_number', pay.provider_ref, 'provider_ref', pay.provider_ref,
    'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
    'locale', case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end,
    'description', 'Sipoonjoen Perinnesauna – tilaus ' || o.order_no::text,
    'site_base_url', booking._setting('site_base_url', 'null'::jsonb) #>> '{}',
    'order_page_path', coalesce(booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}', '/tilaus/'),
    'token_valid_until', coalesce(pay.raw ->> 'token_valid_until', v_until::text),
    'redirect_url', case when v_reuse then pay.raw ->> 'redirect_url' end,
    'customer', v_cust, 'env', coalesce(pay.raw ->> 'env', v_mode));
end $$;

CREATE OR REPLACE FUNCTION booking.public_upsell_add(p_token uuid, p_item jsonb, p_session_id uuid, p_origin bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare o booking.orders; v_first timestamptz; v_product bigint; v_addon bigint; v_result jsonb; v_before bigint; v_new bigint; v_date date;
        v_n int; v_res bigint; v_item jsonb;
begin
  if p_token is null or p_session_id is null or not booking._order_rl('upselladd', p_token, 15, 6) then return jsonb_build_object('ok', false, 'code', 'rate_limited'); end if;
  select * into o from booking.orders where public_token = p_token for update;
  if not found or o.status <> 'confirmed' or o.external_source is not null then return jsonb_build_object('ok', false, 'code', 'order_closed'); end if;
  if booking._order_invoice_locked(o.id) then
    return jsonb_build_object('ok', false, 'code', 'order_invoiced', 'message', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  select min(starts_at) into v_first from booking.reservations where order_id = o.id and booking._res_active(status, hold_expires_at);
  if v_first is null or v_first <= now() + make_interval(mins => booking._upsell_cutoff()) then return jsonb_build_object('ok', false, 'code', 'order_closed'); end if;
  if jsonb_typeof(p_item) <> 'object' or p_item->>'type' not in ('reservation', 'addon') then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
  v_date := (v_first at time zone booking._tz())::date;
  v_item := p_item;
  if p_item->>'type' = 'reservation' then
    if coalesce(p_item->>'product_id', '') !~ '^\d{1,18}$' or p_item->>'start' is null or coalesce(p_item->>'persons', '') !~ '^\d{1,3}$' then
      return jsonb_build_object('ok', false, 'code', 'invalid_items');
    end if;
    v_product := (p_item->>'product_id')::bigint;
    if exists (select 1 from booking.reservations where order_id = o.id and product_id = v_product and booking._res_active(status, hold_expires_at)) then
      return jsonb_build_object('ok', false, 'code', 'duplicate_product');
    end if;
  else
    if coalesce(p_item->>'addon_id', '') !~ '^\d{1,18}$' then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
    v_addon := (p_item->>'addon_id')::bigint;
    if coalesce(p_item->>'reservation_id', '') ~ '^\d{1,18}$' then
      select product_id into v_product from booking.reservations
       where order_id = o.id and id = (p_item->>'reservation_id')::bigint and booking._res_active(status, hold_expires_at);
      if v_product is null then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
    else
      if p_origin is null then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
      select count(*), min(r.id), min(r.product_id) into v_n, v_res, v_product
        from booking.reservations r
       where r.order_id = o.id and r.product_id = p_origin and booking._res_active(r.status, r.hold_expires_at);
      if v_n <> 1 then return jsonb_build_object('ok', false, 'code', 'invalid_items'); end if;
      v_item := v_item || jsonb_build_object('reservation_id', v_res);
    end if;
    if exists (select 1 from booking.order_items where order_id = o.id and addon_id = v_addon) then return jsonb_build_object('ok', false, 'code', 'duplicate_product'); end if;
    if coalesce(v_item->>'quantity', '') !~ '^\d{1,4}$' then v_item := v_item || jsonb_build_object('quantity', 1); end if;
  end if;
  begin
    if p_item->>'type' = 'reservation' then
      if ((p_item->>'start')::timestamptz at time zone booking._tz())::date <> v_date then return jsonb_build_object('ok', false, 'code', 'invalid_date'); end if;
      if not exists (select 1 from booking._upsell_day_slots(v_product, v_date, (p_item->>'persons')::int) q
                     where q.starts_at = (p_item->>'start')::timestamptz) then
        return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
      end if;
    end if;
    select coalesce(max(id), 0) into v_before from booking.order_items where order_id = o.id;
    v_result := booking.public_add_to_order(p_token, jsonb_build_array(v_item));
    if v_result->>'ok' <> 'true' then return jsonb_build_object('ok', false, 'code', coalesce(v_result->>'code', 'invalid_items')); end if;
    select id into v_new from booking.order_items where order_id = o.id and id > v_before order by id desc limit 1;
    if v_new is not null then
      insert into booking.upsell_events(order_id, session_id, source, product_id, suggested_from_product_id, suggested_addon_id, event, order_item_id)
      values (o.id, p_session_id, 'confirmation', v_product, p_origin, v_addon, 'added', v_new) on conflict do nothing;
    end if;
    return jsonb_build_object('ok', true, 'added_total', v_result->'added_total');
  exception when sqlstate 'BK001' or exclusion_violation or invalid_text_representation or datetime_field_overflow then
    return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
  end;
end $f$;
