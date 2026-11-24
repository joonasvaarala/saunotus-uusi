-- booking_347 ROLLBACK: funktiot tavu-identtisinä takaisin.
CREATE OR REPLACE FUNCTION booking._procountor_daily_build(p_date date, p_report jsonb, p_settings jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_receipts int := coalesce((p_report #>> '{totals,receipts}')::int, 0);
  v_refunds int := coalesce((p_report #>> '{totals,refund_receipts}')::int, 0);
  v_rounding numeric := round(coalesce((p_report #>> '{totals,rounding}')::numeric, 0), 2);
  v_unreceipted int := coalesce((p_report #>> '{unreceipted,payments}')::int, 0);
  v_vat_sum numeric := 0;
  v_method_sum numeric := 0;
  v_gc numeric := round(coalesce((p_report #>> '{reconciliation,gift_card_sales}')::numeric, 0), 2);
  v_missing text[] := '{}';
  v_tx jsonb := '[]'::jsonb;
  v_first boolean := true;
  v_status int;
  v_acct text;
  v_method text;
  r record;
begin
  if v_receipts = 0 and v_refunds = 0 and v_gc = 0 then
    if v_unreceipted > 0 then
      return jsonb_build_object('empty', false, 'ready', false, 'missing', jsonb_build_array('unreceipted'), 'request', null);
    end if;
    return jsonb_build_object('empty', true, 'ready', true, 'missing', '[]'::jsonb, 'request', null);
  end if;
  select coalesce(round(sum((e ->> 'gross')::numeric), 2), 0) into v_vat_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e;
  select coalesce(round(sum(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0)), 2), 0) into v_method_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e;
  if abs(v_vat_sum + v_gc - v_method_sum) > 0.05 then
    v_missing := array_append(v_missing, 'imbalance');
  end if;
  if v_unreceipted > 0 then v_missing := array_append(v_missing, 'unreceipted'); end if;
  if coalesce(p_settings ->> 'vat_status', '') ~ '^[0-9]{1,4}$' then v_status := (p_settings ->> 'vat_status')::int;
  else v_missing := array_append(v_missing, 'vat_status'); end if;
  for r in
    select coalesce(e ->> 'method', '') as method,
           round(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0), 2) as net_gross
      from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e
     order by 1
  loop
    if r.net_gross = 0 then continue; end if;
    v_method := nullif(r.method, '');
    v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'clearing_by_method', coalesce(v_method, '')], '')), '');
    if v_acct is null and booking._is_partner_method(v_method) then
      v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'clearing_by_method', 'partner_voucher'], '')), '');
    end if;
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'clearing:' || coalesce(v_method, 'null'));
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct, 'accountingValue', r.net_gross, 'vatPercent', 0,
      'description', 'Maksutapa ' || coalesce(v_method, '?')));
    v_first := false;
  end loop;
  if v_gc <> 0 then
    v_acct := nullif(btrim(coalesce(p_settings ->> 'gift_card_liability', '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'gift_card_liability');
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', 'ENTRY', 'account', v_acct, 'accountingValue', round(-v_gc, 2), 'vatPercent', 0,
      'description', 'Lahjakortti, monikäyttöinen arvoseteli'));
  end if;
  if v_rounding <> 0 then
    v_acct := nullif(btrim(coalesce(p_settings #>> '{accounts,rounding}', '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then v_missing := array_append(v_missing, 'rounding'); v_acct := null; end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct, 'accountingValue', round(-v_rounding, 2), 'vatPercent', 0, 'description', 'Käteispyöristys'));
    v_first := false;
  end if;
  for r in
    select (e ->> 'rate')::numeric as rate, round((e ->> 'net')::numeric, 2) as net
      from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e
     where round(coalesce((e ->> 'net')::numeric, 0), 2) <> 0
     order by 1
  loop
    v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'sales_by_vat', trim_scale(r.rate)::text], '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'sales:' || trim_scale(r.rate)::text);
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', 'ENTRY', 'account', v_acct, 'accountingValue', round(-r.net, 2),
      'vatPercent', r.rate, 'description', 'Myynti ALV ' || trim_scale(r.rate)::text));
  end loop;
  if jsonb_array_length(v_tx) = 0 then v_missing := array_append(v_missing, 'no_lines'); end if;
  return jsonb_build_object('empty', false, 'ready', cardinality(v_missing) = 0, 'missing', to_jsonb(v_missing),
    'request', jsonb_build_object('type', 'JOURNAL', 'status', 'UNFINISHED', 'name', 'Saunotus ' || to_char(p_date, 'YYYY-MM-DD'),
      'receiptDate', to_char(p_date, 'YYYY-MM-DD'), 'vatType', 'SALES', 'vatStatus', v_status, 'transactions', v_tx));
end $function$;

CREATE OR REPLACE FUNCTION booking._accrual_json(p_from date, p_to date, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
  with raw as (
    select r.id as receipt_id, r.kind, r.issued_at, r.order_id, r.original_receipt_id,
           coalesce(l.elem ->> 'description', '') as product,
           coalesce(l.elem ->> 'kind', '') as line_kind,
           coalesce((l.elem ->> 'vat_rate')::numeric, 0) as rate,
           coalesce((l.elem ->> 'quantity')::numeric, 0) as qty,
           booking._snap_line_net(l.elem) as net,
           coalesce((l.elem ->> 'line_gross')::numeric, 0) as gross,
           (r.issued_at at time zone 'Europe/Helsinki')::date as issued_on,
           case
             when coalesce(l.elem ->> 'starts_at', '') ~ '^\d{4}-\d{2}-\d{2}'
               then ((l.elem ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki')::date
           end as line_day
      from booking.receipts r
      cross join lateral jsonb_array_elements(coalesce(r.snapshot -> 'lines', '[]'::jsonb)) as l(elem)
     where not booking._acct_excluded(r.order_id, r.payment_id)
  ), lined as (
    select raw.*,
           coalesce(
             raw.line_day,
             case when raw.kind = 'refund_receipt' then (
               select ((ol.elem ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki')::date
                 from booking.receipts orig
                 cross join lateral jsonb_array_elements(coalesce(orig.snapshot -> 'lines', '[]'::jsonb)) ol(elem)
                where orig.id = raw.original_receipt_id
                  and coalesce(ol.elem ->> 'starts_at', '') ~ '^\d{4}-\d{2}-\d{2}'
                  and coalesce(ol.elem ->> 'description', '') = raw.product
                limit 1
             ) end,
             (select min((rr.starts_at at time zone 'Europe/Helsinki')::date)
                from booking.reservations rr
               where rr.order_id = raw.order_id),
             raw.issued_on
           ) as service_on
      from raw
  ), svc as (
    select * from lined where line_kind is distinct from 'gift_card'
  ), sales as (
    select product, rate,
           sum(qty) as quantity,
           sum(net) as net,
           sum(gross - net) as vat,
           sum(gross) as gross
      from svc
     where kind = 'receipt' and service_on between p_from and p_to
     group by product, rate
  ), refs as (
    select product, rate,
           sum(abs(qty)) as quantity,
           sum(abs(net)) as net,
           sum(abs(gross - net)) as vat,
           sum(abs(gross)) as gross
      from svc
     where kind = 'refund_receipt' and service_on between p_from and p_to
     group by product, rate
  ), sales_vat as (
    select rate, sum(quantity) as quantity, sum(net) as net, sum(vat) as vat, sum(gross) as gross
      from sales group by rate
  ), refs_vat as (
    select rate, sum(quantity) as quantity, sum(net) as net, sum(vat) as vat, sum(gross) as gross
      from refs group by rate
  ), adv as (
    select rate,
           sum(net) as net,
           sum(gross - net) as vat,
           sum(gross) as gross,
           count(*) filter (where kind = 'receipt') as sale_lines
      from svc
     where issued_on <= p_as_of and service_on > p_as_of
     group by rate
  ), gc as (
    select count(*) filter (where bal > 0.004)::int as cards,
           coalesce(sum(bal) filter (where bal > 0.004), 0) as gross
      from (
        select coalesce((
                 select sum(l.delta)
                   from booking.gift_card_ledger l
                  where l.gift_card_id = g.id
                    and (l.at at time zone 'Europe/Helsinki')::date <= p_as_of
               ), 0) as bal
          from booking.gift_cards g
         where g.accounting_origin is distinct from 'johku'
           and g.source is distinct from 'johku'
           and g.external_source is distinct from 'johku'
           and coalesce(g.complimentary, false) = false
           and g.vat_treatment = 'at_sale'
           and (g.valid_to is null or g.valid_to >= p_as_of)
           and (coalesce(g.activated_at, g.created_at) at time zone 'Europe/Helsinki')::date <= p_as_of
      ) s
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki',
                                 'kind', case when p_from = p_to then 'day' else 'range' end),
    'generated_at', now(),
    'basis', 'service (palvelupäivä, Europe/Helsinki)',
    'as_of', p_as_of,
    'sales_by_product', coalesce((
      select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by product, rate)
        from sales), '[]'::jsonb),
    'sales_by_vat', coalesce((
      select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by rate)
        from sales_vat), '[]'::jsonb),
    'refunds_by_product', coalesce((
      select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by product, rate)
        from refs), '[]'::jsonb),
    'refunds_by_vat', coalesce((
      select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by rate)
        from refs_vat), '[]'::jsonb),
    'totals', jsonb_build_object(
      'sales_net', coalesce((select sum(net) from sales), 0),
      'sales_vat', coalesce((select sum(vat) from sales), 0),
      'sales_gross', coalesce((select sum(gross) from sales), 0),
      'refunds_net', coalesce((select sum(net) from refs), 0),
      'refunds_vat', coalesce((select sum(vat) from refs), 0),
      'refunds_gross', coalesce((select sum(gross) from refs), 0),
      'net', coalesce((select sum(net) from sales), 0) - coalesce((select sum(net) from refs), 0),
      'vat', coalesce((select sum(vat) from sales), 0) - coalesce((select sum(vat) from refs), 0),
      'gross', coalesce((select sum(gross) from sales), 0) - coalesce((select sum(gross) from refs), 0)
    ),
    'advances', jsonb_build_object(
      'as_of', p_as_of,
      'services', jsonb_build_object(
        'net', coalesce((select sum(net) from adv), 0),
        'vat', coalesce((select sum(vat) from adv), 0),
        'gross', coalesce((select sum(gross) from adv), 0),
        'lines', coalesce((select sum(sale_lines) from adv), 0),
        'by_vat', coalesce((
          select jsonb_agg(jsonb_build_object('rate', rate, 'net', net, 'vat', vat, 'gross', gross) order by rate)
            from adv), '[]'::jsonb)
      ),
      'gift_cards_unused', jsonb_build_object(
        'count', (select cards from gc),
        'gross', (select gross from gc),
        'vat', round((select gross from gc) * 25.5 / 125.5, 2),
        'net', (select gross from gc) - round((select gross from gc) * 25.5 / 125.5, 2),
        'rate', 25.5,
        'vat_at_sale', true
      ),
      'total_gross', coalesce((select sum(gross) from adv), 0) + (select gross from gc)
    )
  ) into v;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_get_procountor_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.integration_config;
begin
  perform booking._require_permission('settings.edit');
  select * into c from booking.integration_config where key = 'procountor';
  return jsonb_build_object(
    'ok', true,
    'mode', coalesce(c.mode, 'off'),
    'environment', case when c.settings->>'environment' = 'prod' then 'prod' else 'pts' end,
    'daily_enabled', coalesce(c.settings->>'daily_enabled', 'false') = 'true',
    'api_prefix', coalesce(nullif(c.settings->>'api_prefix', ''), '/supported/api'),
    'vat_status', coalesce(c.settings->>'vat_status', ''),
    'approved_by', coalesce(c.settings->>'approved_by', ''),
    'bank_account', coalesce(c.settings->>'bank_account', ''),
    'accounts', jsonb_build_object(
      'rounding', coalesce(c.settings#>>'{accounts,rounding}', ''),
      'sales_by_vat', coalesce(c.settings#>'{accounts,sales_by_vat}', '{}'::jsonb),
      'clearing_by_method', coalesce(c.settings#>'{accounts,clearing_by_method}', '{}'::jsonb)));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_set_procountor_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cur booking.integration_config;
  s jsonb; v_mode text; env text; approved text; vat text; prefix text; iban text;
  accounts jsonb; sales jsonb := '{}'::jsonb; clearing jsonb := '{}'::jsonb; rounding text;
  k text; v text;
  rates text[] := array['25.5','13.5','0','14','24','10'];
  methods text[] := array['cash','card_terminal','mobilepay','bank_transfer','invoice','gift_card','partner_voucher','partner_voucher_kokemuskauppa','partner_voucher_offerilla','partner_voucher_elamyslahjat','visma_pay','montonio','annual_card','pay_later','other'];
begin
  perform booking._require_permission('settings.edit');
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_setting', 'Asetusten pitää olla objekti'); end if;
  if booking._json_has_secret_key(p) then perform booking._err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin'); end if;
  select * into cur from booking.integration_config where key = 'procountor';
  if not found then perform booking._err('not_configured', 'procountor-asetus puuttuu'); end if;
  v_mode := coalesce(nullif(btrim(p->>'mode'), ''), cur.mode);
  if v_mode not in ('off', 'dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  env := lower(btrim(coalesce(p->>'environment', cur.settings->>'environment', 'pts')));
  if env in ('sandbox', '') then env := 'pts'; end if;
  if env not in ('pts', 'prod') then perform booking._err('invalid_setting', 'Ympäristö on pts tai prod'); end if;
  if p ? 'approved_by' then approved := btrim(coalesce(p->>'approved_by', ''));
  else approved := btrim(coalesce(cur.settings->>'approved_by', '')); end if;
  if approved <> '' and (char_length(approved) < 3 or char_length(approved) > 80 or approved like 'eyJ%') then
    perform booking._err('invalid_setting', 'approved_by on nimi ja päivä, ei tunnusta');
  end if;
  if v_mode = 'live' and approved = '' then perform booking._err('approval_required', 'Yhdistetty tila vaatii approved_by'); end if;
  if p ? 'daily_enabled' and jsonb_typeof(p->'daily_enabled') is distinct from 'boolean' then perform booking._err('invalid_setting', 'daily_enabled on totuusarvo'); end if;
  if p ? 'vat_status' then vat := btrim(coalesce(p->>'vat_status', ''));
  else vat := btrim(coalesce(cur.settings->>'vat_status', '')); end if;
  if vat <> '' and vat !~ '^[0-9]{1,4}$' then perform booking._err('invalid_setting', 'ALV-tila on 1–4 numeroa'); end if;
  prefix := btrim(coalesce(nullif(p->>'api_prefix', ''), cur.settings->>'api_prefix', '/supported/api'));
  if prefix !~ '^/api$|^/latest/api$|^/supported/api$|^/v[0-9]{4}/api$' then perform booking._err('invalid_setting', 'API-etuliite ei kelpaa'); end if;
  if p ? 'bank_account' then iban := upper(regexp_replace(coalesce(p->>'bank_account', ''), '\s', '', 'g'));
  else iban := coalesce(cur.settings->>'bank_account', ''); end if;
  if iban <> '' and iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then perform booking._err('invalid_setting', 'Tilinumero on IBAN tai tyhjä'); end if;
  accounts := coalesce(p->'accounts', '{}'::jsonb);
  if jsonb_typeof(accounts) <> 'object' then perform booking._err('invalid_setting', 'accounts on objekti'); end if;
  rounding := btrim(coalesce(accounts->>'rounding', ''));
  if rounding <> '' and rounding !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
  if accounts ? 'sales_by_vat' then
    if jsonb_typeof(accounts->'sales_by_vat') <> 'object' then perform booking._err('invalid_setting', 'sales_by_vat on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'sales_by_vat') loop
      if not (k = any (rates)) then perform booking._err('invalid_setting', 'Tuntematon ALV-kanta: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then sales := sales || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if accounts ? 'clearing_by_method' then
    if jsonb_typeof(accounts->'clearing_by_method') <> 'object' then perform booking._err('invalid_setting', 'clearing_by_method on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'clearing_by_method') loop
      if not (k = any (methods)) then perform booking._err('invalid_setting', 'Tuntematon maksutapa: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then clearing := clearing || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if v_mode = 'live' and (vat !~ '^[0-9]{1,4}$' or sales = '{}'::jsonb or clearing = '{}'::jsonb) then
    perform booking._err('live_incomplete', 'Yhdistetty tila vaatii ALV-tilan, vähintään yhden myyntitilin ja maksutavan tilin');
  end if;
  s := coalesce(cur.settings, '{}'::jsonb)
    || jsonb_build_object(
         'environment', env,
         'daily_enabled', case when p ? 'daily_enabled' then (p->>'daily_enabled')::boolean else coalesce((cur.settings->>'daily_enabled')::boolean, false) end,
         'api_prefix', prefix,
         'vat_status', vat,
         'approved_by', nullif(approved, ''),
         'bank_account', nullif(iban, ''),
         'accounts', jsonb_build_object('rounding', nullif(rounding, ''), 'sales_by_vat', sales, 'clearing_by_method', clearing));
  s := jsonb_strip_nulls(s);
  update booking.integration_config
     set mode = v_mode, settings = s, updated_by = auth.uid()
   where key = 'procountor';
  return booking.admin_get_procountor_settings();
end $function$;
