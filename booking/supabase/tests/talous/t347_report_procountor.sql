begin;
-- t347: Procountor-päivätosite (K5) ja suoriteperusteen lahjakorttien ALV (K10). booking_347, 25.11.2026.
-- Vaatii migraation 347 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback. Ei Procountor-kutsuja.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t347_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t347_r values (coalesce(p_ok, false), p_label) $$;
do $t$
declare
  u_adm uuid := test.mk_staff('adm@t347.example', 'admin');
  d date := (now() at time zone 'Europe/Helsinki')::date;
  rep jsonb; st jsonb; b jsonb; r jsonb; v jsonb; n1 text; n2 text; g bigint; acc jsonb;
begin
  -- K5 A: ALV-pyöristys: 10,04 × 25,5 % = 2,56 (Procountor), raportissa 2,55 → rivi +0,01
  rep := '{"totals":{"receipts":1,"refund_receipts":0,"rounding":0},"by_vat":[{"rate":25.5,"net":10.04,"vat":2.55,"gross":12.59}],"by_method":[{"method":"card_terminal","gross":12.59,"refunds":0}],"reconciliation":{"gift_card_sales":0}}';
  st := '{"vat_status":1,"accounts":{"clearing_by_method":{"card_terminal":"1700"},"sales_by_vat":{"25.5":"3000"}}}';
  b := booking._procountor_daily_build('2031-03-03', rep, st);
  perform pg_temp.ck(not (b ->> 'ready')::boolean and b -> 'missing' ? 'vat_rounding', 'A1: tili puuttuu → missing vat_rounding ' || (b -> 'missing')::text);
  perform pg_temp.ck((b ->> 'vat_rounding')::numeric = -0.01, 'A2: erotus −0,01 (raportti − Procountor)');
  b := booking._procountor_daily_build('2031-03-03', rep, jsonb_set(st, '{accounts,vat_rounding}', '"8790"'));
  perform pg_temp.ck((b ->> 'ready')::boolean, 'A3: tilillä valmis ' || (b -> 'missing')::text);
  select e into r from jsonb_array_elements(b #> '{request,transactions}') e where e ->> 'description' like 'ALV-pyöristys%';
  perform pg_temp.ck(r ->> 'description' = 'ALV-pyöristys, päivätosite 03.03.', 'A4b: selite ALV-pyöristys, päivätosite pp.kk. ' || coalesce(r ->> 'description', 'null'));
  perform pg_temp.ck(r ->> 'account' = '8790' and (r ->> 'accountingValue')::numeric = 0.01 and (r ->> 'vatPercent')::numeric = 0, 'A4: rivi tilille 8790, +0,01, ALV 0 ' || coalesce(r::text, 'null'));
  -- tasapaino: veloitus (maksutavat) = hyvitys (netto + Procountorin ALV) + pyöristysrivi
  perform pg_temp.ck((select sum((e ->> 'accountingValue')::numeric + case when (e ->> 'vatPercent')::numeric > 0 then round((e ->> 'accountingValue')::numeric * (e ->> 'vatPercent')::numeric / 100, 2) else 0 end)
                        from jsonb_array_elements(b #> '{request,transactions}') e) = 0, 'A5: tosite täsmää Procountorin ALV-laskennalla');
  -- B: ei erotusta → ei riviä eikä vaatimusta
  rep := jsonb_set(jsonb_set(rep, '{by_vat,0,vat}', '2.56'), '{by_vat,0,gross}', '12.60');
  rep := jsonb_set(rep, '{by_method,0,gross}', '12.60');
  b := booking._procountor_daily_build('2031-03-03', rep, st);
  perform pg_temp.ck((b ->> 'ready')::boolean and (b ->> 'vat_rounding')::numeric = 0
                     and not exists (select 1 from jsonb_array_elements(b #> '{request,transactions}') e where e ->> 'description' like 'ALV-pyöristys%'), 'B1: ei erotusta → ei riviä ' || (b -> 'missing')::text);
  perform pg_temp.ck(b #>> '{request,name}' = 'Saunotus 2031-03-03', 'B2: ilman kuitteja nimi ennallaan ' || (b #>> '{request,name}'));
  perform pg_temp.ck(b #>> '{attachments,0,kind}' = 'daily_report_pdf' and b #>> '{attachments,0,name}' = 'Saunotus-paivaraportti-2031-03-03.pdf', 'B3: liitekuvaus');
  perform pg_temp.ck(not (b -> 'request') ? 'attachments' and not (b -> 'request') ? 'receipt_range', 'B4: Procountorin request-runko ei saa uusia kenttiä');
  -- C: kuittinumerot nimeen
  perform test.login(u_adm);
  v := booking.admin_create_gift_card('open', 40, 1, jsonb_build_object('name', 'Olli', 'email', 'olli@t347.example'), null, null, null, 'card_terminal', null, null, 'fi', 'testi', 'admin', 'buyer');
  v := booking.admin_create_gift_card('open', 50, 1, jsonb_build_object('name', 'Olli', 'email', 'olli@t347.example'), null, null, null, 'card_terminal', null, null, 'fi', 'testi', 'admin', 'buyer');
  perform test.logout();
  select min(receipt_no), max(receipt_no) into n1, n2 from booking.receipts where kind = 'receipt' and (issued_at at time zone 'Europe/Helsinki')::date = d;
  b := booking._procountor_daily_build(d, rep, st);
  perform pg_temp.ck(n1 is not null and n1 <> n2 and b #>> '{request,name}' = 'Saunotus ' || to_char(d, 'YYYY-MM-DD') || ' (kuitit ' || n1 || '–' || n2 || ')', 'C1: kuittiväli nimessä ' || coalesce(b #>> '{request,name}', 'null'));
  perform pg_temp.ck(b #>> '{receipt_range,receipts_from}' = n1 and b #>> '{receipt_range,receipts_to}' = n2 and b #>> '{receipt_range,refunds_from}' is null, 'C2: receipt_range');
  perform pg_temp.ck(length(b #>> '{request,name}') <= 200, 'C3: nimi enintään 200 merkkiä');

  -- D: asetus accounts.vat_rounding tallentuu ja validoituu (ei kytkimiä päälle)
  perform test.login(u_adm);
  v := booking.admin_get_procountor_settings();
  perform test.logout();
  perform pg_temp.ck(v #>> '{accounts,vat_rounding}' = '', 'D1: get palauttaa vat_rounding (tyhjä) ' || coalesce(v #>> '{accounts}', 'null'));
  perform test.login(u_adm);
  v := booking.admin_set_procountor_settings(jsonb_set(v, '{accounts,vat_rounding}', '"8790"'));
  perform test.logout();
  perform pg_temp.ck(v #>> '{accounts,vat_rounding}' = '8790' and coalesce(v ->> 'daily_enabled', 'false') = 'false' and coalesce(v ->> 'mode', 'off') = (select coalesce(mode, 'off') from booking.integration_config where key = 'procountor'), 'D2: tallennettu 8790; daily_enabled pois');
  perform test.login(u_adm);
  begin
    perform booking.admin_set_procountor_settings(jsonb_set(v, '{accounts,vat_rounding}', '"87 90"'));
    n1 := 'ok';
  exception when others then
    n1 := sqlstate;
  end;
  perform test.logout();
  perform pg_temp.ck(n1 = 'BK001', 'D3: virheellinen tili hylätään (' || n1 || ')');

  -- K10: lahjakorttien käyttämätön saldo, ALV kortin omasta kannasta
  insert into booking.gift_cards(code, issuer, initial_amount, balance, status, vat_treatment, sale_vat_rate, accounting_origin, source, complimentary, activated_at, valid_from, valid_to)
  values ('HHT347AA2550', 'own', 125.5, 125.5, 'active', 'at_sale', 25.5, 'native', 'native', false, '2032-06-01 10:00:00+00', '2032-06-01', '2033-06-01') returning id into g;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at) values (g, 125.5, 125.5, 'purchase', '2032-06-01 10:00:00+00');
  acc := booking._accrual_json('2032-06-01', '2032-06-30', '2032-06-30');
  perform pg_temp.ck((acc #>> '{advances,gift_cards_unused,vat}')::numeric = 25.5 and (acc #>> '{advances,gift_cards_unused,rate}')::numeric = 25.5, 'K1: yksi kanta 25,5 → ALV 25,50, rate 25,5 ' || (acc #> '{advances,gift_cards_unused}')::text);
  insert into booking.gift_cards(code, issuer, initial_amount, balance, status, vat_treatment, sale_vat_rate, accounting_origin, source, complimentary, activated_at, valid_from, valid_to)
  values ('HHT347BB1350', 'own', 113.5, 113.5, 'active', 'at_sale', 13.5, 'native', 'native', false, '2032-06-02 10:00:00+00', '2032-06-02', '2033-06-01') returning id into g;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at) values (g, 113.5, 113.5, 'purchase', '2032-06-02 10:00:00+00');
  insert into booking.gift_cards(code, issuer, initial_amount, balance, status, vat_treatment, sale_vat_rate, accounting_origin, source, complimentary, activated_at, valid_from, valid_to)
  values ('HHT347CC0000', 'own', 10, 10, 'active', 'at_sale', 0, 'native', 'native', false, '2032-06-02 10:00:00+00', '2032-06-02', '2033-06-01') returning id into g;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at) values (g, 10, 10, 'purchase', '2032-06-02 10:00:00+00');
  acc := booking._accrual_json('2032-06-01', '2032-06-30', '2032-06-30');
  perform pg_temp.ck((acc #>> '{advances,gift_cards_unused,gross}')::numeric = 249 and (acc #>> '{advances,gift_cards_unused,vat}')::numeric = 39 and (acc #>> '{advances,gift_cards_unused,net}')::numeric = 210, 'K2: 25,50 + 13,50 + 0 = 39 ALV ' || (acc #> '{advances,gift_cards_unused}')::text);
  perform pg_temp.ck(acc #> '{advances,gift_cards_unused,rate}' = 'null'::jsonb and jsonb_array_length(acc #> '{advances,gift_cards_unused,by_rate}') = 3, 'K3: useita kantoja → rate null, by_rate 3 riviä');
  perform pg_temp.ck((acc #>> '{advances,gift_cards_unused,cards_without_rate}')::int = 0 and (acc #>> '{advances,gift_cards_unused,count}')::int = 3, 'K4: kortteja 3, ilman kantaa 0');
  perform pg_temp.ck((acc #>> '{advances,total_gross}')::numeric = (acc #>> '{advances,services,gross}')::numeric + 249, 'K5: total_gross ennallaan (palvelut + korttien brutto)');
  perform pg_temp.ck(position('25.5 / 125.5' in pg_get_functiondef('booking._accrual_json'::regproc)) = 0, 'K6: ei kiinteää 25,5/125,5-kerrointa');
end $t$;
do $r$
declare n int; f text;
begin
  select count(*), string_agg(label, ' | ') filter (where not ok) into n, f from t347_r;
  raise notice 'TESTRESULT pass=% fail=% %', n - (select count(*) from t347_r where not ok), (select count(*) from t347_r where not ok), coalesce(f, ':: ALL OK');
end $r$;
rollback;
