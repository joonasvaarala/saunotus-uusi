-- booking_336_johku_refunds
-- Johkun kautta maksettujen varausten käsin tehdyt hyvitykset (esim. MobilePay Johkussa -> pankkisiirto).
-- Ei booking.refunds-tauluun: uudessa järjestelmässä ei ole vastaavaa maksua.
-- Pyyntö: Joonas Asiakaspalvelun chatissa t330u 22.11.2026 klo 10.58.

create table if not exists booking.johku_refunds (
  id bigint generated always as identity primary key,
  johku_order_no text not null check (btrim(johku_order_no) <> ''),
  order_id bigint references booking.orders(id) on delete restrict,
  customer_name text not null check (btrim(customer_name) <> ''),
  customer_email text,
  amount numeric(12,2) not null check (amount > 0),
  original_payment_method text not null check (btrim(original_payment_method) <> ''),
  refund_method text not null check (btrim(refund_method) <> ''),
  refund_date date not null,
  note text not null check (btrim(note) <> ''),
  created_at timestamptz not null default now(),
  created_by text not null default 'Asiakaspalvelu',
  created_by_uid uuid
);
comment on table booking.johku_refunds is 'Johkussa maksettujen varausten käsin tehdyt hyvitykset (ei kirjanpidon kuittihyvityksiä, ei booking.refunds). Kirjataan booking.svc_record_johku_refund-funktiolla. booking_336.';
comment on column booking.johku_refunds.amount is 'Hyvitetty summa euroina (sama esitystapa kuin booking.refunds.amount).';
create index if not exists johku_refunds_refund_date_idx on booking.johku_refunds (refund_date);
create index if not exists johku_refunds_johku_order_no_idx on booking.johku_refunds (johku_order_no);
create index if not exists johku_refunds_order_id_idx on booking.johku_refunds (order_id) where order_id is not null;
alter table booking.johku_refunds enable row level security;
revoke all on table booking.johku_refunds from public, anon, authenticated;
grant select, insert on table booking.johku_refunds to service_role;

create or replace function booking.svc_record_johku_refund(
  p_johku_order_no text,
  p_customer_name text,
  p_amount numeric,
  p_original_payment_method text,
  p_refund_method text,
  p_refund_date date,
  p_note text,
  p_order_id bigint default null,
  p_customer_email text default null,
  p_allow_duplicate boolean default false,
  p_actor text default 'Asiakaspalvelu'
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_actor text := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_jno text := nullif(btrim(coalesce(p_johku_order_no, '')), '');
  v_name text := nullif(btrim(coalesce(p_customer_name, '')), '');
  v_email text := nullif(lower(btrim(coalesce(p_customer_email, ''))), '');
  v_orig text := nullif(btrim(coalesce(p_original_payment_method, '')), '');
  v_meth text := nullif(btrim(coalesce(p_refund_method, '')), '');
  v_today date := (now() at time zone 'Europe/Helsinki')::date;
  v_order_no bigint; v_order_jno bigint; v_dup bigint; v_warn jsonb := '[]'::jsonb;
  r booking.johku_refunds;
begin
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if v_jno is null then perform booking._err('invalid_data', 'Anna Johku-tilausnumero (p_johku_order_no)'); end if;
  if v_name is null then perform booking._err('invalid_data', 'Anna asiakkaan nimi (p_customer_name)'); end if;
  if v_orig is null then perform booking._err('invalid_data', 'Anna alkuperäinen maksutapa (p_original_payment_method)'); end if;
  if v_meth is null then perform booking._err('invalid_data', 'Anna hyvitystapa (p_refund_method)'); end if;
  if p_amount is null or p_amount <= 0 then perform booking._err('invalid_amount', 'Summan pitää olla suurempi kuin 0'); end if;
  if p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Summa euroina enintään kahdella desimaalilla'); end if;
  if p_refund_date is null then perform booking._err('invalid_data', 'Anna hyvityspäivä (p_refund_date)'); end if;
  if p_refund_date > v_today then perform booking._err('invalid_date', 'Hyvityspäivä ei voi olla tulevaisuudessa'); end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform booking._err('invalid_email', 'Virheellinen sähköpostiosoite'); end if;
  if p_order_id is not null then
    select o.order_no, o.johku_order_no into v_order_no, v_order_jno from booking.orders o where o.id = p_order_id;
    if not found then perform booking._err('order_not_found', 'Tilausta ei löydy (p_order_id)'); end if;
    if v_order_jno is not null and v_order_jno::text <> v_jno then
      v_warn := v_warn || jsonb_build_array(format('Tilauksen Johku-numero on %s, annettu %s', v_order_jno, v_jno));
    end if;
  end if;
  select j.id into v_dup from booking.johku_refunds j
   where j.johku_order_no = v_jno and j.amount = p_amount and j.refund_date = p_refund_date limit 1;
  if v_dup is not null and not coalesce(p_allow_duplicate, false) then
    perform booking._err('duplicate', format('Sama hyvitys on jo kirjattu (id %s). Jos kyse on eri hyvityksestä, anna p_allow_duplicate => true', v_dup));
  end if;
  insert into booking.johku_refunds(johku_order_no, order_id, customer_name, customer_email, amount, original_payment_method, refund_method, refund_date, note, created_by, created_by_uid)
  values (v_jno, p_order_id, v_name, v_email, p_amount, v_orig, v_meth, p_refund_date, v_note, v_actor, auth.uid())
  returning * into r;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'johku_refunds', r.id::text, 'SVC_RECORD_JOHKU_REFUND', null,
          jsonb_build_object('johku_order_no', r.johku_order_no, 'order_id', r.order_id, 'amount', r.amount, 'refund_date', r.refund_date,
                             'original_payment_method', r.original_payment_method, 'refund_method', r.refund_method, 'note', r.note, 'actor', v_actor));
  return jsonb_build_object('ok', true, 'id', r.id, 'johku_order_no', r.johku_order_no, 'order_id', r.order_id, 'order_no', v_order_no,
    'customer_name', r.customer_name, 'customer_email', r.customer_email, 'amount', r.amount,
    'original_payment_method', r.original_payment_method, 'refund_method', r.refund_method, 'refund_date', r.refund_date,
    'note', r.note, 'created_at', r.created_at, 'created_by', r.created_by, 'warnings', v_warn);
end $function$;
revoke all on function booking.svc_record_johku_refund(text, text, numeric, text, text, date, text, bigint, text, boolean, text) from public, anon, authenticated;
grant execute on function booking.svc_record_johku_refund(text, text, numeric, text, text, date, text, bigint, text, boolean, text) to service_role;

create or replace function booking._report_johku_refunds(p_from date, p_to date)
returns jsonb
language sql
stable security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'label', 'Johkun kautta tulleiden varausten hyvitykset',
    'accounting', false,
    'basis', 'refund_date',
    'info', 'Johkussa maksettujen varausten käsin tehdyt hyvitykset. Eivät sisälly uuden järjestelmän kuitteihin, maksutapoihin eikä hyvityksiin.',
    'count', count(j.id),
    'total', coalesce(sum(j.amount), 0),
    'by_refund_method', coalesce((select jsonb_agg(jsonb_build_object('refund_method', m.refund_method, 'count', m.c, 'total', m.t) order by m.refund_method)
        from (select x.refund_method, count(*) c, sum(x.amount) t from booking.johku_refunds x where x.refund_date between p_from and p_to group by 1) m), '[]'::jsonb),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
        'id', j.id, 'refund_date', j.refund_date, 'johku_order_no', j.johku_order_no, 'order_id', j.order_id, 'order_no', o.order_no,
        'customer_name', j.customer_name, 'amount', j.amount, 'original_payment_method', j.original_payment_method,
        'refund_method', j.refund_method, 'note', j.note, 'created_by', j.created_by, 'created_at', j.created_at)
      order by j.refund_date, j.id) filter (where j.id is not null), '[]'::jsonb))
  from booking.johku_refunds j
  left join booking.orders o on o.id = j.order_id
  where j.refund_date between p_from and p_to
$function$;
revoke all on function booking._report_johku_refunds(date, date) from public, anon, authenticated;
grant execute on function booking._report_johku_refunds(date, date) to service_role;

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
  v := v || jsonb_build_object('johku_refunds', booking._report_johku_refunds(p_date, p_date));
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
  v := v || jsonb_build_object('johku_refunds', booking._report_johku_refunds(v_from, (v_from + interval '1 month' - interval '1 day')::date));
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
  v := v || jsonb_build_object('johku_refunds', booking._report_johku_refunds(p_from, p_to));
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
  if p_kind is null or p_kind not in ('lines', 'transactions', 'summary', 'vat', 'methods', 'johku_refunds') then perform booking._err('invalid_param', 'p_kind: lines|transactions|summary|vat|methods|johku_refunds'); end if;
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
  elsif p_kind = 'johku_refunds' then
    v_hdr := 'hyvityspvm;johku_tilaus;tilaus;asiakas;summa;alkuperainen_maksutapa;hyvitystapa;selite';
    fn := case when p_from = p_to then format('johku_hyvitykset_%s.csv', p_from) else format('johku_hyvitykset_%s_%s.csv', p_from, p_to) end;
    rep := booking._report_johku_refunds(p_from, p_to);
    for el in select * from jsonb_array_elements(rep -> 'rows') loop
      v_body := v_body || concat_ws(';', to_char((el ->> 'refund_date')::date, 'DD.MM.YYYY'), booking._csv(el ->> 'johku_order_no'), booking._csv(el ->> 'order_no'),
        booking._csv(el ->> 'customer_name'), booking._csvmoney((el ->> 'amount')::numeric), booking._csv(el ->> 'original_payment_method'),
        booking._csv(el ->> 'refund_method'), booking._csv(el ->> 'note')) || v_cr;
    end loop;
    v_body := v_body || concat_ws(';', 'yhteensa', '', '', '', booking._csvmoney(coalesce((rep ->> 'total')::numeric, 0)), '', '', '') || v_cr;
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

insert into kb.bot_permissions(botti, botti_id, toimenpide, ehdot, hyvaksyja, hyvaksynta_viite, paivamaara, voimassa)
select 'Asiakaspalvelu', 'fefd4229-b9f6-425c-ba91-381135ef01b7'::uuid,
  'Johkun kautta maksettujen varausten hyvitysten kirjaus: booking.svc_record_johku_refund (taulu booking.johku_refunds).',
  'Kirjaa vain jo tehdyn, käsin (esim. verkkopankista) maksetun hyvityksen Johkussa maksetulle varaukselle. Ei kirjausta booking.refunds-tauluun, ei rahansiirtoa, ei kuittia, ei tilauksen tai maksun tilan muutosta, ei poistoja eikä muokkauksia. Pakolliset: Johku-tilausnumero, asiakas, summa > 0 euroina, alkuperäinen maksutapa, hyvitystapa, hyvityspäivä (ei tulevaisuudessa) ja p_note, joka viittaa Joonaksen pyyntöön. p_order_id vain jos tilaus on uudessa järjestelmässä. Sama Johku-tilaus + summa + päivä hylätään (duplicate), ellei p_allow_duplicate => true erillisestä hyvityksestä. Näkyy päivä- ja kuukausiraportin osiossa johku_refunds.',
  'Joonas Vaarala', 't330u (Asiakaspalvelun chat, 22.11.2026 klo 10.58)', date '2026-11-22', true
where not exists (select 1 from kb.bot_permissions where toimenpide like 'Johkun kautta maksettujen varausten hyvitysten kirjaus%');
