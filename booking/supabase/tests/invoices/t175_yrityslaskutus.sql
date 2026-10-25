-- t175: booking_175 yrityslaskutus (väliaikainen migraatio 20261025070000).
--   A rakenne: md5 (4 korvattua funktiota = booking_175, riippuvuudet + booking_173/174 = tuotanto), asetus invoice_reference_prefix, oikeudet.
--   B _clean_company: laskutustapa einvoice / pdf / puuttuu (vanha käytös) / virheellinen → BK001 invalid_invoice_method; PDF ei vaadi eikä tallenna OVT:tä.
--   C verkkokaupan yritystilaus + verkkolasku → lasku numeroidaan ja menee lähetysjonoon automaattisesti (dry_run-tilassa dispatch_status dry_run,
--     live-tilassa queued; tila muutetaan vain tämän transaktion sisällä). Asiakkaan OVT + välittäjä laskun asiakaskuvaan, rekisteri ennallaan.
--   D verkkokaupan PDF-tilaus → luonnos, ei jonoa. E hallinnan tilaus (admin_create_booking, laskutustapa verkkolasku) → luonnos, ei jonoa,
--     kunnes "Lähetä verkkolasku" (admin_send_invoice). F viite: etuliite 7310, 7-3-1-tarkiste, enintään 20 merkkiä, vanhat viitteet ennallaan,
--     asetuksen muutos huomioidaan, virheellinen etuliite → BK001 invalid_setting. G automaattilähetyksen virhe ei kaada tilausta (audit_log).
--   H Procountor-asetukset (integration_config) ennallaan, ei sähköposteja tässä polussa, ei jäänteitä.
-- TUOTANTOKELPOINEN: yksi transaktio (BEGIN … lopussa tahallinen poikkeus "TESTRESULT pass=… fail=… skip=…" + ROLLBACK), ei kiinteitä id-arvoja (RETURNING),
-- testikäyttäjät luodaan transaktion sisällä (auth.users + booking.staff, gen_random_uuid), ei psql-metakomentoja → toimii myös pelkällä SQL-työkalulla.
-- Apufunktiot pg_temp-skeemassa (ei public-skeemaa). Virheet tarkistetaan SQLSTATE + BK001-detail -koodeilla, ei virhetekstein.
-- Verkkokaupan polku ajetaan sekä oikealla public_create_booking-kutsulla (vapaa yleinen vuoro haetaan; jos ei löydy → skip) että suoralla tilausrivillä.
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t175_yrityslaskutus.sql   (tai liitä koko tiedosto SQL-editoriin; tulos virheviestissä TESTRESULT …)
-- Jälkitarkistus ROLLBACKin jälkeen (erillinen SELECT tiedoston lopussa): t175 leftover rows = 0.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t175.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t175.log', coalesce(current_setting('t175.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.skip(p_label text) returns void language sql as $$
  select set_config('t175.log', coalesce(current_setting('t175.log', true), '') || 'S ' || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
-- ajaa lausekkeen; palauttaa jsonb-tuloksen tai {"state": SQLSTATE, "err": BK001-detail | SQLSTATE}
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; s text;
begin execute 'select (' || p_sql || ')::jsonb' into r; return coalesce(r, 'null'::jsonb);
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end);
end $$;
-- ajaa lauseen (myös void-funktiot); palauttaa {"state":"ok"} tai {"state": SQLSTATE, "err": BK001-detail | SQLSTATE}
create function pg_temp.exec(p_sql text) returns jsonb language plpgsql as $$
declare d text; s text;
begin execute 'select ' || p_sql; return '{"state":"ok"}'::jsonb;
exception when others then get stacked diagnostics d = pg_exception_detail; s := sqlstate; return jsonb_build_object('state', s, 'err', case when s = 'BK001' then d else s end);
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
-- satunnainen kelvollinen y-tunnus (painot 7,9,10,5,8,4,2; jakojäännös 1 ei kelpaa → uusi arvonta)
create function pg_temp.bid() returns text language plpgsql volatile as $$
declare d text; s int; r int;
begin
  loop
    d := '9' || lpad((floor(random() * 1000000))::int::text, 6, '0');
    s := substr(d,1,1)::int*7 + substr(d,2,1)::int*9 + substr(d,3,1)::int*10 + substr(d,4,1)::int*5 + substr(d,5,1)::int*8 + substr(d,6,1)::int*4 + substr(d,7,1)::int*2;
    r := s % 11;
    exit when r <> 1;
  end loop;
  return d || '-' || case when r = 0 then 0 else 11 - r end;
end $$;
-- itsenäinen 7-3-1-tarkiste: viitteen viimeinen numero = tarkiste muista
create function pg_temp.ref_ok(p_ref text) returns boolean language plpgsql immutable as $$
declare b text; s int := 0; w int[] := array[7,3,1]; i int; n int;
begin
  if p_ref is null or p_ref !~ '^[0-9]{4,20}$' then return false; end if;
  b := left(p_ref, -1); n := char_length(b);
  for i in 1..n loop s := s + substr(b, n - i + 1, 1)::int * w[((i - 1) % 3) + 1]; end loop;
  return right(p_ref, 1)::int = (10 - s % 10) % 10;
end $$;
create function pg_temp.company(p_bid text, p_method text, p_ovt boolean) returns jsonb language sql as $$
  select jsonb_build_object('company_name', 'T175 Testi Oy', 'business_id', p_bid, 'street', 'Testikatu 1', 'zip', '00100', 'city', 'Helsinki')
      || case when p_method is not null then jsonb_build_object('invoice_method', p_method) else '{}'::jsonb end
      || case when p_ovt then jsonb_build_object('einvoice_address', '0037' || replace(p_bid, '-', ''), 'einvoice_operator', '003723327487') else '{}'::jsonb end $$;
-- verkkokaupan yritystilaus suoraan (sama järjestys kuin public_create_booking: tilaus + billing → laskumaksu → payment_status unpaid)
create function pg_temp.web_order(p_bid text, p_method text, p_ovt boolean, p_channel text) returns bigint language plpgsql as $$
declare v_cu bigint; v_o bigint; v_cc jsonb := booking._clean_company(pg_temp.company(p_bid, p_method, p_ovt));
begin
  v_cu := booking._upsert_company_customer('company', 'T175 Yhteys', 't175-' || replace(p_bid, '-', '') || '@example.test', '0401234567', v_cc, false, 'web', 'fi');
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_kind)
  values (v_cu, 'confirmed', 'pending', 62, p_channel, 'fi', 'company') returning id into v_o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_o, 'T175 saunavuoro', 'product', 2, 31, 62, 25.5);
  perform booking._stamp_order_billing(v_o, v_cu, v_cc);
  insert into booking.payments(order_id, method, provider, status, amount) values (v_o, 'invoice', 'manual', 'pending', 62);
  update booking.orders set payment_status = 'unpaid' where id = v_o;
  return v_o;
end $$;

do $t$
declare
  run text := lower(substr(md5(random()::text), 1, 8));
  u_adm uuid := gen_random_uuid();
  cfg0 jsonb; mode0 jsonb; pre0 jsonb; mail0 bigint; ref_old jsonb;
  r jsonb; o bigint; i booking.invoices; i2 booking.invoices; b1 text; b2 text; b3 text; b4 text; b5 text; ic0 jsonb; ic1 jsonb;
  d date; rl record; cnt int; m text; logt text; np int; nf int; ns int;
begin
  select to_jsonb(c) into cfg0 from booking.integration_config c where key = 'procountor';
  select value into mode0 from booking.settings where key = 'invoice_dispatch_mode';
  select value into pre0 from booking.settings where key = 'invoice_reference_prefix';
  select count(*) into mail0 from booking.email_outbox;
  select coalesce(jsonb_object_agg(id, reference_no), '{}') into ref_old from booking.invoices where reference_no is not null;
  insert into auth.users(id, email) values (u_adm, 't175-admin-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't175-admin-' || run || '@example.test', 't175 admin', 'admin');

  -- ===== A rakenne
  perform pg_temp.ck(md5(pg_get_functiondef('booking._clean_company(jsonb)'::regprocedure)) = '53fa5a8a98e98aeb4a97000d2f6b37ec', 'A1 _clean_company = booking_175');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._stamp_order_billing(bigint,bigint,jsonb)'::regprocedure)) = '693f24abfe0dddfbf4a2e345e1596e73', 'A2 _stamp_order_billing = booking_175');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._invoice_allocate(bigint)'::regprocedure)) = '46a3326812f896077fc2614ba783ff3d', 'A3 _invoice_allocate = booking_175');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.orders_invoice_draft_trg()'::regprocedure)) = 'df1d0ebf036380495f6730d1fa93de7a', 'A4 orders_invoice_draft_trg = booking_175');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._invoice_queue_dispatch(bigint)'::regprocedure)) = 'f3cfdb0e2d484ab6f63c6286c4ff8560'
      and md5(pg_get_functiondef('booking._ensure_draft_invoice(bigint)'::regprocedure)) = 'eefa8e82c7aab1a148bdb3e319ae65ae'
      and md5(pg_get_functiondef('booking._fi_reference(text)'::regprocedure)) = 'f7c4076dcc85d8efc97e7335c349da2c'
      and md5(pg_get_functiondef('booking.admin_send_invoice(bigint,boolean,boolean)'::regprocedure)) = '7ea29743e8e199c74ced1d62c730b27f'
      and md5(pg_get_functiondef('booking.orders_invoice_status_trg()'::regprocedure)) = '9ec5c212604145e284fa07d2fd2686f6'
      and md5(pg_get_functiondef('booking.invoices_lock_trg()'::regprocedure)) = '63f39183d475f2b04bcc7a9e9aaf251e', 'A5 laskutuksen riippuvuudet = tuotanto (ei muutettu)');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure)) = 'de9084871640d213d10527a045157bf2'
      and md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure)) = '2db9a1233a06e6293d0877f17de1ab72'
      and md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) = '525d1fa96fd7c37df4d7e502edf1bf71'
      and md5(pg_get_functiondef('booking._vc_due(booking.orders,booking.voucher_claims)'::regprocedure)) = 'bea9cd9a32eb273ee72caed0aedd1e2e', 'A6 booking_173/174 ennallaan');
  perform pg_temp.ck(pre0 = '"7310"'::jsonb and not (select is_public from booking.settings where key = 'invoice_reference_prefix'), 'A7 asetus invoice_reference_prefix = "7310", ei julkinen');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._clean_company(jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'booking._invoice_allocate(bigint)', 'execute')
      and not has_function_privilege('anon', 'booking._stamp_order_billing(bigint,bigint,jsonb)', 'execute'), 'A8 sisäiset funktiot eivät ole suoraan kutsuttavissa');
  perform pg_temp.ck(exists (select 1 from pg_trigger where tgname = 'orders_invoice_draft' and tgrelid = 'booking.orders'::regclass and not tgisinternal), 'A9 trigger orders_invoice_draft olemassa');

  -- testin oma tila: verkkolaskujen lähetystila dry_run (kuten tuotannossa), vain tässä transaktiossa
  update booking.settings set value = '"dry_run"'::jsonb where key = 'invoice_dispatch_mode';
  b1 := pg_temp.bid(); b2 := pg_temp.bid(); b3 := pg_temp.bid(); b4 := pg_temp.bid(); b5 := pg_temp.bid();

  -- ===== B _clean_company
  r := booking._clean_company(pg_temp.company(b1, 'pdf', true));
  perform pg_temp.ck(r ->> 'invoice_method' = 'pdf' and coalesce(r ->> 'einvoice_address', '') = '' and coalesce(r ->> 'einvoice_operator', '') = '', 'B1 PDF: laskutustapa pdf, OVT ja välittäjä tyhjennetään');
  r := booking._clean_company(pg_temp.company(b1, 'PDF', false) || '{"require_einvoice":true}');
  perform pg_temp.ck(r ->> 'invoice_method' = 'pdf', 'B2 PDF ohittaa require_einvoice-lipun eikä vaadi OVT:tä (kirjainkoko ei merkitse)');
  r := booking._clean_company(pg_temp.company(b1, 'einvoice', true));
  perform pg_temp.ck(r ->> 'invoice_method' = 'einvoice' and r ->> 'einvoice_address' = '0037' || replace(b1, '-', ''), 'B3 verkkolasku: OVT tallentuu');
  r := pg_temp.call(format('booking._clean_company(%L::jsonb)', pg_temp.company(b1, 'einvoice', false)));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'einvoice_incomplete', 'B4 verkkolasku ilman OVT:tä → BK001 einvoice_incomplete');
  r := pg_temp.call(format('booking._clean_company(%L::jsonb)', pg_temp.company(b1, 'paperi', false)));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'invalid_invoice_method', 'B5 tuntematon laskutustapa → BK001 invalid_invoice_method');
  r := booking._clean_company(pg_temp.company(b1, null, false));
  perform pg_temp.ck(not (r ? 'invoice_method'), 'B6 ilman laskutustapaa (hallinta, vanha käytös): ei invoice_method-kenttää, OVT vapaaehtoinen');
  r := pg_temp.call(format('booking._clean_company(%L::jsonb)', pg_temp.company(b1, null, false) || '{"require_einvoice":true}'));
  perform pg_temp.ck(r ->> 'err' = 'einvoice_incomplete', 'B7 vanha require_einvoice ilman OVT:tä → einvoice_incomplete kuten ennen');

  -- ===== C verkkokauppa + verkkolasku → automaattisesti jonoon
  o := pg_temp.web_order(b2, 'einvoice', true, 'web');
  select * into i from booking.invoices where order_id = o and kind = 'debit';
  perform pg_temp.ck((select payment_status from booking.orders where id = o) = 'invoiced', 'C1 tilaus laskutettu (payment_status invoiced → tagi Laskutettu)');
  perform pg_temp.ck((select billing ->> 'invoice_method' from booking.orders where id = o) = 'einvoice', 'C2 tilauksen billing.invoice_method = einvoice');
  perform pg_temp.ck(i.status = 'sent' and i.invoice_no is not null, 'C3 lasku numeroitu ilman lähetysnappia');
  perform pg_temp.ck(i.dispatch_status = 'dry_run' and (select count(*) from booking.invoice_dispatch_log where invoice_id = i.id and status = 'dry_run') = 1, 'C4 dry_run-tilassa: dispatch_status dry_run + yksi lokirivi (ei lähetystä)');
  perform pg_temp.ck(i.customer_snapshot ->> 'einvoice_address' = '0037' || replace(b2, '-', '') and i.customer_snapshot ->> 'einvoice_operator' = '003723327487' and i.customer_snapshot_locked, 'C5 laskun asiakaskuvassa tilauksen OVT + välittäjä, kuva lukittu');
  perform pg_temp.ck(left(i.reference_no, 4) = '7310' and pg_temp.ref_ok(i.reference_no) and char_length(i.reference_no) <= 20, 'C6 viite 7310…, 7-3-1-tarkiste oikein, enintään 20 merkkiä');
  perform pg_temp.ck(i.reference_no = booking._fi_reference('7310' || (substring(i.invoice_no from '[0-9]+$'))::bigint::text), 'C7 viite = _fi_reference(7310 || laskun järjestysnumero)');
  -- live-tila (vain transaktiossa): sama polku → queued (cron/edge ei näe kommitoimatonta riviä; edge-provider on dry-run)
  update booking.settings set value = '"live"'::jsonb where key = 'invoice_dispatch_mode';
  o := pg_temp.web_order(b3, 'einvoice', true, 'web');
  select * into i2 from booking.invoices where order_id = o and kind = 'debit';
  perform pg_temp.ck(i2.status = 'sent' and i2.dispatch_status = 'queued' and (select count(*) from booking.invoice_dispatch_log where invoice_id = i2.id and status = 'queued') = 1, 'C8 live-tilassa verkkolasku menee jonoon (queued)');
  perform pg_temp.ck(i2.reference_no <> i.reference_no and pg_temp.ref_ok(i2.reference_no), 'C9 seuraava lasku saa oman viitteen');
  update booking.settings set value = '"dry_run"'::jsonb where key = 'invoice_dispatch_mode';
  -- rekisterissä vanhat (tyhjät) OVT-tiedot → laskulle silti tilauksen tiedot, rekisteri ennallaan
  insert into booking.invoice_customers(company_name, business_id, email) values ('T175 Rekisteri Oy', b5, 'rek-' || run || '@example.test');
  select to_jsonb(x) - 'updated_at' into ic0 from booking.invoice_customers x where business_id = b5;
  o := pg_temp.web_order(b5, 'einvoice', true, 'web');
  select * into i from booking.invoices where order_id = o and kind = 'debit';
  select to_jsonb(x) - 'updated_at' into ic1 from booking.invoice_customers x where business_id = b5;
  perform pg_temp.ck(i.dispatch_status = 'dry_run' and i.customer_snapshot ->> 'einvoice_address' = '0037' || replace(b5, '-', ''), 'C10 rekisteriasiakas ilman OVT:tä: lasku saa tilauksen OVT:n ja menee jonoon');
  perform pg_temp.ck(ic0 = ic1, 'C11 laskuasiakasrekisteri ei muutu');
  -- oikea verkkokaupan varaus (public_create_booking, anon), jos vapaa yleinen vuoro löytyy
  r := null;
  <<haku>>
  for rl in select sr.id, sr.weekdays from booking.schedule_rules sr where sr.active and sr.mode = 'shared' and sr.kind = 'regular' order by sr.id loop
    for k in 3..45 loop
      d := current_date + k;
      continue when not (extract(isodow from d)::smallint = any (rl.weekdays));
      execute 'set local role anon';
      r := pg_temp.call(format($q$booking.public_create_booking(%s, %L::date, 2, 'T175 Yhteys', %L, '0401234567', false, 'fi', null, 'company', %L::jsonb, null)$q$,
             rl.id, d, 't175-web-' || run || '@example.test', pg_temp.company(b4, 'einvoice', true)));
      execute 'reset role';
      exit haku when coalesce((r ->> 'ok')::boolean, false);
      r := null;
    end loop;
  end loop;
  if r is null then
    perform pg_temp.skip('C12 public_create_booking: vapaata yleistä vuoroa ei löytynyt');
    perform pg_temp.skip('C13 public_create_booking PDF');
  else
    select * into i from booking.invoices iv join booking.orders od on od.id = iv.order_id where od.public_token = (r ->> 'token')::uuid and iv.kind = 'debit';
    perform pg_temp.ck(i.status = 'sent' and i.dispatch_status = 'dry_run' and left(i.reference_no, 4) = '7310' and pg_temp.ref_ok(i.reference_no)
                       and (select source_channel from booking.orders where id = i.order_id) = 'web', 'C12 public_create_booking + verkkolasku → lasku numeroitu ja jonossa automaattisesti');
    execute 'set local role anon';
    r := pg_temp.call(format($q$booking.public_create_booking(%s, %L::date, 2, 'T175 Pdf', %L, '0401234567', false, 'fi', null, 'company', %L::jsonb, null)$q$,
           rl.id, d, 't175-pdf-' || run || '@example.test', pg_temp.company(pg_temp.bid(), 'pdf', false)));
    execute 'reset role';
    select * into i from booking.invoices iv join booking.orders od on od.id = iv.order_id where od.public_token = (r ->> 'token')::uuid and iv.kind = 'debit';
    perform pg_temp.ck(coalesce((r ->> 'ok')::boolean, false) and i.status = 'draft' and i.dispatch_status = 'none' and i.reference_no is null, 'C13 public_create_booking + PDF → luonnos, ei jonoa');
  end if;

  -- ===== D verkkokauppa + PDF → luonnos
  o := pg_temp.web_order(pg_temp.bid(), 'pdf', false, 'web');
  select * into i from booking.invoices where order_id = o and kind = 'debit';
  perform pg_temp.ck(i.status = 'draft' and i.invoice_no is null and i.reference_no is null, 'D1 PDF-laskutapa: lasku jää luonnokseksi');
  perform pg_temp.ck(i.dispatch_status = 'none' and not exists (select 1 from booking.invoice_dispatch_log where invoice_id = i.id), 'D2 PDF: ei lähetysjonoa');
  perform pg_temp.ck((select billing ->> 'invoice_method' from booking.orders where id = o) = 'pdf' and (select billing ->> 'einvoice_address' from booking.orders where id = o) is null, 'D3 PDF: billing.invoice_method pdf, ei OVT:tä');

  -- ===== E hallinnan tilaus → luonnos, jonoon vasta napista
  o := pg_temp.web_order(pg_temp.bid(), 'einvoice', true, 'admin');
  select * into i from booking.invoices where order_id = o and kind = 'debit';
  perform pg_temp.ck(i.status = 'draft' and i.dispatch_status = 'none', 'E1 hallinnan kanava + verkkolasku: luonnos, ei jonoa');
  perform pg_temp.login(u_adm);
  r := null;
  for rl in select sr.id, sr.weekdays from booking.schedule_rules sr where sr.active and sr.mode = 'shared' and sr.kind = 'regular' order by sr.id loop
    for k in 3..45 loop
      d := current_date + k;
      continue when not (extract(isodow from d)::smallint = any (rl.weekdays));
      r := pg_temp.call(format($q$booking.admin_create_booking(%s, %L::date, 2, null, %L::jsonb, 'invoice')$q$, rl.id, d,
             jsonb_build_object('kind', 'company', 'name', 'T175 Hallinta', 'email', 't175-adm-' || run || '@example.test', 'company_details', pg_temp.company(b4, 'einvoice', true))));
      exit when r ? 'order_id';
      r := null;
    end loop;
    exit when r is not null;
  end loop;
  if r is null then
    perform pg_temp.logout();
    perform pg_temp.skip('E2–E4 admin_create_booking: vapaata vuoroa ei löytynyt');
  else
    perform pg_temp.logout();
    select * into i from booking.invoices where order_id = (r ->> 'order_id')::bigint and kind = 'debit';
    perform pg_temp.ck((select source_channel || '|' || payment_status || '|' || (billing ->> 'invoice_method') from booking.orders where id = (r ->> 'order_id')::bigint) = 'admin|invoiced|einvoice'
                       and i.status = 'draft' and i.dispatch_status = 'none' and i.reference_no is null, 'E2 admin_create_booking + verkkolasku → luonnos, ei jonoa');
    perform pg_temp.login(u_adm);
    r := pg_temp.call(format('booking.admin_send_invoice(%s, true, false)', i.id));
    perform pg_temp.logout();
    select * into i from booking.invoices where id = i.id;
    perform pg_temp.ck(i.status = 'sent' and i.dispatch_status = 'dry_run' and left(i.reference_no, 4) = '7310' and pg_temp.ref_ok(i.reference_no), 'E3 "Lähetä verkkolasku" → numero + viite 7310 + jono');
    perform pg_temp.login(u_adm);
    r := pg_temp.call(format('booking.admin_send_invoice(%s, true, false)', i.id));
    perform pg_temp.logout();
    perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'already_sent', 'E4 toinen lähetys → BK001 already_sent');
  end if;

  -- ===== F viite ja asetus
  perform pg_temp.ck(not exists (select 1 from jsonb_each_text(ref_old) e join booking.invoices x on x.id = e.key::bigint where x.reference_no is distinct from e.value), 'F1 vanhat viitteet ennallaan');
  update booking.settings set value = '"123456789"'::jsonb where key = 'invoice_reference_prefix';
  o := pg_temp.web_order(pg_temp.bid(), 'einvoice', true, 'web');
  select * into i from booking.invoices where order_id = o and kind = 'debit';
  perform pg_temp.ck(left(i.reference_no, 9) = '123456789' and pg_temp.ref_ok(i.reference_no) and char_length(i.reference_no) <= 20, 'F2 asetuksen muutos huomioidaan (etuliite 123456789, tarkiste oikein, ≤ 20)');
  update booking.settings set value = '"0731"'::jsonb where key = 'invoice_reference_prefix';
  o := pg_temp.web_order(pg_temp.bid(), 'pdf', false, 'web');
  select * into i from booking.invoices where order_id = o and kind = 'debit';
  perform pg_temp.login(u_adm);
  r := pg_temp.call(format('booking.admin_send_invoice(%s, false, false)', i.id));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'invalid_param', 'F3 ei lähetystapaa → BK001 invalid_param (ennallaan)');
  r := pg_temp.exec(format('booking._invoice_allocate(%s)', i.id));
  perform pg_temp.logout();
  perform pg_temp.ck(r ->> 'state' = '42501', 'F4 _invoice_allocate ei kutsuttavissa henkilökunnan roolilla (42501)');
  r := pg_temp.exec(format('booking._invoice_allocate(%s)', i.id));
  perform pg_temp.ck(r ->> 'state' = 'BK001' and r ->> 'err' = 'invalid_setting', 'F5 etuliite alkaa nollalla → BK001 invalid_setting');
  update booking.settings set value = '"7310x"'::jsonb where key = 'invoice_reference_prefix';
  r := pg_temp.exec(format('booking._invoice_allocate(%s)', i.id));
  perform pg_temp.ck(r ->> 'err' = 'invalid_setting' and (select status from booking.invoices where id = i.id) = 'draft', 'F6 ei-numeerinen etuliite → invalid_setting, lasku ennallaan luonnos');
  delete from booking.settings where key = 'invoice_reference_prefix';
  r := pg_temp.exec(format('booking._invoice_allocate(%s)', i.id));
  select * into i from booking.invoices where id = i.id;
  perform pg_temp.ck(i.status = 'sent' and left(i.reference_no, 4) = '7310' and pg_temp.ref_ok(i.reference_no), 'F7 asetus puuttuu → oletus 7310');
  insert into booking.settings(key, value, description, is_public) values ('invoice_reference_prefix', pre0, 't175 palautus', false);

  -- ===== G automaattilähetyksen virhe ei kaada tilausta
  update booking.settings set value = '"0"'::jsonb where key = 'invoice_reference_prefix';
  o := pg_temp.web_order(pg_temp.bid(), 'einvoice', true, 'web');
  select * into i from booking.invoices where order_id = o and kind = 'debit';
  perform pg_temp.ck(i.status = 'draft' and i.dispatch_status = 'none' and (select payment_status from booking.orders where id = o) = 'invoiced', 'G1 virhe (virheellinen etuliite): tilaus syntyy, lasku jää luonnokseksi');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where row_pk = o::text and action = 'invoice_auto_send_failed' and new_data ->> 'sqlstate' = 'BK001'), 'G2 virhe kirjataan audit_logiin (invoice_auto_send_failed)');
  update booking.settings set value = pre0 where key = 'invoice_reference_prefix';

  -- ===== H ei sivuvaikutuksia
  perform pg_temp.ck((select to_jsonb(c) from booking.integration_config c where key = 'procountor') = cfg0, 'H1 Procountor-asetukset ennallaan (mode, daily_enabled)');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where kind = 'invoice_pdf' and created_at >= now()), 'H2 PDF-laskusähköpostia ei jonotettu');
  update booking.settings set value = mode0 where key = 'invoice_dispatch_mode';
  perform pg_temp.ck((select value from booking.settings where key = 'invoice_dispatch_mode') is not distinct from mode0, 'H3 invoice_dispatch_mode palautettu');

  logt := current_setting('t175.log', true);
  np := (select count(*) from regexp_split_to_table(logt, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(logt, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(logt, E'\n') l where l like 'S %');
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, E'\n' || logt;
end $t$;
rollback;

-- Jälkitarkistus (erillinen kysely ROLLBACKin jälkeen): odotus 0.
select 't175 leftover rows' as check, (select count(*) from booking.invoice_customers where company_name like 'T175 %')
     + (select count(*) from booking.staff where email like 't175-%@example.test')
     + (select count(*) from booking.customers where email like 't175-%@example.test') as n;
