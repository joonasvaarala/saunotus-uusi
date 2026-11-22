-- ROLLBACK booking_336_johku_refunds
-- Palauttaa raporttifunktiot booking_336:ta edeltäneeseen muotoon (md5: daily dfb8524f…, month 9a56e154…, range 8284749…, csv 9a95342e…).
-- HUOM: taulun pudotus poistaa kirjatut Johku-hyvitykset. Ota ensin talteen: select * from booking.johku_refunds;
CREATE OR REPLACE FUNCTION booking.admin_report_daily(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
  perform booking._report_check(false);
  if p_date is null then perform booking._err('invalid_param', 'Anna päivämäärä'); end if;
  v := booking._report_json(p_date, p_date, true, false);
  v := jsonb_set(v, '{totals,gross_after_refunds}', v -> 'totals' -> 'net_after_refunds');
  return jsonb_set(v, '{period,kind}', '"day"'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_report_month(p_ym text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_from date; v jsonb;
begin
  perform booking._report_check(true);
  if p_ym is null or p_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then perform booking._err('invalid_param', 'Kuukausi muodossa YYYY-MM'); end if;
  v_from := (p_ym || '-01')::date;
  v := booking._report_json(v_from, (v_from + interval '1 month' - interval '1 day')::date, false, true);
  v := jsonb_set(v, '{totals,gross_after_refunds}', v -> 'totals' -> 'net_after_refunds');
  return jsonb_set(v, '{period,kind}', '"month"'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_report_range(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  v := booking._report_json(p_from, p_to, false, p_to > p_from);
  v := jsonb_set(v, '{totals,gross_after_refunds}', v -> 'totals' -> 'net_after_refunds');
  return jsonb_set(v, '{period,kind}', '"range"'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_report_csv(p_from date, p_to date, p_kind text DEFAULT 'lines'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_body text := ''; v_hdr text; v_cr text := E'\r\n'; rep jsonb; el jsonb; rec jsonb; fn text;
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)'); end if;
  if p_kind is null or p_kind not in ('lines', 'transactions', 'summary', 'vat', 'methods') then perform booking._err('invalid_param', 'p_kind: lines|transactions|summary|vat|methods'); end if;
  if p_kind in ('lines', 'transactions') then
    v_hdr := 'tosite;pvm;asiakas;tuote;maara;netto;alv_%;alv_eur;brutto;maksutapa;tila;laji';
    fn := format('tapahtumat_%s_%s.csv', p_from, p_to);
    select coalesce(string_agg(concat_ws(';',
             booking._csv(t.x ->> 'voucher'),
             to_char((t.x ->> 'date')::date, 'DD.MM.YYYY'),
             booking._csv(t.x ->> 'customer'),
             booking._csv(t.x ->> 'product'),
             booking._csvnum(coalesce((t.x ->> 'quantity')::numeric, 0)),
             booking._csvmoney(coalesce((t.x ->> 'net')::numeric, 0)),
             booking._csvnum(coalesce((t.x ->> 'vat_rate')::numeric, 0)),
             booking._csvmoney(coalesce((t.x ->> 'vat')::numeric, 0)),
             booking._csvmoney(coalesce((t.x ->> 'gross')::numeric, 0)),
             booking._csv(coalesce(nullif(t.x ->> 'method_label', ''), t.x ->> 'method')),
             case t.x ->> 'status' when 'open' then 'avoin' else 'maksettu' end,
             case t.x ->> 'kind' when 'refund' then 'hyvitys' when 'redemption' then 'lunastus' else 'myynti' end), v_cr order by t.n), '')
      into v_body
      from jsonb_array_elements(booking._report_tx(p_from, p_to)) with ordinality as t(x, n);
  elsif p_kind = 'summary' then
    v_hdr := 'osio;nimi;alv_%;maara;netto;alv_eur;brutto';
    fn := case when p_from = p_to then format('myynti_%s.csv', p_from) else format('myynti_%s_%s.csv', p_from, p_to) end;
    rep := booking._report_json(p_from, p_to, false, false);
    for el in select * from jsonb_array_elements(rep -> 'by_product') loop
      v_body := v_body || concat_ws(';', 'myynti', booking._csv(el ->> 'product'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'refunds_by_product') loop
      v_body := v_body || concat_ws(';', 'hyvitys', booking._csv(el ->> 'product'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'prepaid_redemptions' -> 'lines') loop
      v_body := v_body || concat_ws(';', 'lunastus', booking._csv(el ->> 'product'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_vat_sales') loop
      v_body := v_body || concat_ws(';', 'alv_myynti', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), '',
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_vat_refunds') loop
      v_body := v_body || concat_ws(';', 'alv_hyvitys', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), '',
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_vat') loop
      v_body := v_body || concat_ws(';', 'alv', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), '',
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'gift_card_period' -> 'sold' -> 'by_vat') loop
      v_body := v_body || concat_ws(';', 'lahjakortti_myyty', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'prepaid_redemptions' -> 'by_vat') loop
      v_body := v_body || concat_ws(';', 'lahjakortti_lunastus', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    rec := rep -> 'reconciliation';
    v_body := v_body || concat_ws(';', 'tasmaytys', 'myynti_brutto', '', '', '', '', booking._csvmoney((rec ->> 'sales_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'hyvitykset_brutto', '', '', '', '', booking._csvmoney((rec ->> 'refunds_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'tuotteet', '', '', '', '', booking._csvmoney((rec ->> 'product_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'alv_rivi', '', '', '', booking._csvmoney((rec ->> 'line_vat')::numeric), '') || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'alv_myynti', '', '', '', booking._csvmoney((rec ->> 'receipt_vat')::numeric), '') || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', coalesce(rec ->> 'rounding_code', 'alv_pyoristys'), '', '', '', booking._csvmoney((rec ->> 'vat_rounding')::numeric), '') || v_cr;
    if abs(coalesce((rec ->> 'cash_rounding')::numeric, 0)) >= 0.005 then
      v_body := v_body || concat_ws(';', 'tasmaytys', 'kateispyoristys', '', '', '', '', booking._csvmoney((rec ->> 'cash_rounding')::numeric)) || v_cr;
    end if;
    v_body := v_body || concat_ws(';', 'lahjakortti_avoin', 'oma_alkusaldo', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,opening}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_avoin', 'oma_loppusaldo', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,closing}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_vanhentunut', 'oma', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,expired}')::numeric, 0))) || v_cr;
  elsif p_kind = 'methods' then
    v_hdr := 'maksutapa;maksuja;myynti_brutto;hyvitykset;netto';
    fn := case when p_from = p_to then format('maksutavat_%s.csv', p_from) else format('maksutavat_%s_%s.csv', p_from, p_to) end;
    rep := booking._report_json(p_from, p_to, false, false);
    for el in select * from jsonb_array_elements(rep -> 'by_method') loop
      v_body := v_body || concat_ws(';', booking._csv(coalesce(el ->> 'label', el ->> 'method')),
        booking._csvnum(coalesce((el ->> 'payments')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'refunds')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0) + coalesce((el ->> 'refunds')::numeric, 0))) || v_cr;
    end loop;
    v_body := v_body || concat_ws(';', 'tasmaytys', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,money_received}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'myynti_hyvitysten_jalkeen', '', '', '', booking._csvmoney(coalesce((rep #>> '{totals,net_after_refunds}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_lunastus', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,gift_card_redemptions}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_myyty', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,gift_card_sales}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'laskutettu', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,invoiced}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'erotus', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,methods_difference}')::numeric, 0))) || v_cr;
    for el in select * from jsonb_array_elements(coalesce(rep -> 'open' -> 'rows', '[]'::jsonb)) loop
      v_body := v_body || concat_ws(';', 'avoin', booking._csv(el ->> 'voucher'), booking._csv(el ->> 'product'),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)), booking._csv(el ->> 'customer')) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_method_vat') loop
      v_body := v_body || concat_ws(';', 'alv_' || booking._csv(el ->> 'method'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
  else
    v_hdr := 'pvm;tosite;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto';
    fn := format('myynti_vat_%s_%s.csv', p_from, p_to);
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), r.receipt_no, o.order_no::text, case when r.kind = 'receipt' then 'myynti' else 'hyvitys' end,
             booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csvnum((v.e ->> 'rate')::numeric), booking._csvmoney((v.e ->> 'net')::numeric),
             booking._csvmoney((v.e ->> 'vat')::numeric), booking._csvmoney((v.e ->> 'gross')::numeric)), v_cr order by r.issued_at, r.id, v.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'vat') with ordinality as v(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id)
       and coalesce(r.snapshot -> 'payment' ->> 'method', '') is distinct from 'invoice'
       and coalesce((r.snapshot ->> 'informational')::boolean, false) = false;
  end if;
  return jsonb_build_object('filename', fn, 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || v_hdr || v_cr || v_body || case when v_body <> '' then v_cr else '' end);
end $function$;

update kb.bot_permissions set voimassa = false where toimenpide like 'Johkun kautta maksettujen varausten hyvitysten kirjaus%';
drop function if exists booking._report_johku_refunds(date, date);
drop function if exists booking.svc_record_johku_refund(text, text, numeric, text, text, date, text, bigint, text, boolean, text);
-- drop table if exists booking.johku_refunds;  -- vain kun data on otettu talteen ja Joonas hyväksyy
