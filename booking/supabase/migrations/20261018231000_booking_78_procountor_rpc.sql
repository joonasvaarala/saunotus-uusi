-- booking_78_procountor_rpc (18.10.2026)
-- Päivän myyntikirjaus kuitin raportista (booking._report_json, ei rinnakkainen ALV-laskenta)
-- ja laskun välityksen idempotentti varaus. Oikeus: palvelu, tilan luku settings.edit.
-- Rollback: rollbacks/20261018231000_booking_78_ROLLBACK.sql

-- Koostaa Procountor-päiväkirjan (JOURNAL) raportin by_vat / by_method / totals.rounding -kentistä.
-- Tilit tulevat integration_config.settings.accounts. Puuttuva tili ei ole arvaus: rivi saa account=null ja missing-listan.
create function booking._procountor_daily_build(p_date date, p_report jsonb, p_settings jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_receipts int := coalesce((p_report #>> '{totals,receipts}')::int, 0);
  v_refunds int := coalesce((p_report #>> '{totals,refund_receipts}')::int, 0);
  v_rounding numeric := round(coalesce((p_report #>> '{totals,rounding}')::numeric, 0), 2);
  v_unreceipted int := coalesce((p_report #>> '{unreceipted,payments}')::int, 0);
  v_vat_sum numeric := 0;
  v_method_sum numeric := 0;
  v_missing text[] := '{}';
  v_tx jsonb := '[]'::jsonb;
  v_first boolean := true;
  v_status int;
  v_acct text;
  v_method text;
  r record;
begin
  if v_receipts = 0 and v_refunds = 0 then
    if v_unreceipted > 0 then
      return jsonb_build_object('empty', false, 'ready', false, 'missing', jsonb_build_array('unreceipted'), 'request', null);
    end if;
    return jsonb_build_object('empty', true, 'ready', true, 'missing', '[]'::jsonb, 'request', null);
  end if;

  select coalesce(round(sum((e ->> 'gross')::numeric), 2), 0) into v_vat_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e;
  select coalesce(round(sum(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0)), 2), 0) into v_method_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e;
  if abs(v_vat_sum - v_method_sum) > 0.05 then
    v_missing := array_append(v_missing, 'imbalance');
  end if;
  if v_unreceipted > 0 then
    v_missing := array_append(v_missing, 'unreceipted');
  end if;

  if coalesce(p_settings ->> 'vat_status', '') ~ '^[0-9]{1,4}$' then
    v_status := (p_settings ->> 'vat_status')::int;
  else
    v_missing := array_append(v_missing, 'vat_status');
  end if;

  for r in
    select coalesce(e ->> 'method', '') as method,
           round(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0), 2) as net_gross
      from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e
     order by 1
  loop
    if r.net_gross = 0 then continue; end if;
    v_method := nullif(r.method, '');
    v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'clearing_by_method', coalesce(v_method, '')], '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'clearing:' || coalesce(v_method, 'null'));
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct,
      'accountingValue', r.net_gross,
      'vatPercent', 0,
      'description', 'Maksutapa ' || coalesce(v_method, '?')));
    v_first := false;
  end loop;

  if v_rounding <> 0 then
    v_acct := nullif(btrim(coalesce(p_settings #>> '{accounts,rounding}', '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'rounding');
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct,
      'accountingValue', round(-v_rounding, 2),
      'vatPercent', 0,
      'description', 'Käteispyöristys'));
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
    -- Myyntirivi on aina ENTRY. REVERSING_ENTRY sallii vain vatPercent 0 (Procountor Transaction).
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', 'ENTRY',
      'account', v_acct,
      'accountingValue', round(-r.net, 2),
      'vatPercent', r.rate,
      'description', 'Myynti ALV ' || trim_scale(r.rate)::text));
  end loop;

  if jsonb_array_length(v_tx) = 0 then
    v_missing := array_append(v_missing, 'no_lines');
  end if;

  return jsonb_build_object(
    'empty', false,
    'ready', cardinality(v_missing) = 0,
    'missing', to_jsonb(v_missing),
    'request', jsonb_build_object(
      'type', 'JOURNAL',
      'status', 'UNFINISHED',
      'name', 'Saunotus ' || to_char(p_date, 'YYYY-MM-DD'),
      'receiptDate', to_char(p_date, 'YYYY-MM-DD'),
      'vatType', 'SALES',
      'vatStatus', v_status,
      'transactions', v_tx));
end $function$;

create function booking.procountor_daily_prepare(p_date date default null, p_force_dry_run boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_date date;
  v_mode text;
  v_settings jsonb;
  v_enabled boolean;
  v_env text;
  v_report jsonb;
  v_built jsonb;
  v_id bigint;
  v_status text;
  v_action text;
  v_err text;
  v_row booking.accounting_exports%rowtype;
  v_today date := (now() at time zone 'Europe/Helsinki')::date;
begin
  if booking._jwt_role() in ('anon', 'authenticated') then
    perform booking._err('forbidden', 'Vain palvelu');
  end if;

  select c.mode, c.settings into v_mode, v_settings from booking.integration_config c where c.key = 'procountor';
  v_mode := coalesce(v_mode, 'off');
  v_settings := coalesce(v_settings, '{}'::jsonb);
  v_enabled := coalesce(v_settings ->> 'daily_enabled', 'false') = 'true';
  v_env := case when v_settings ->> 'environment' = 'prod' then 'prod' else 'pts' end;

  if v_mode = 'off' or not v_enabled then
    return jsonb_build_object('ok', true, 'action', 'skip', 'reason', 'disabled', 'mode', v_mode, 'daily_enabled', v_enabled);
  end if;

  if p_date is null then
    select e.business_date into v_date
      from booking.accounting_exports e
     where e.kind = 'daily_sales'
       and e.business_date >= v_today - 14
       and e.business_date < v_today
       and e.attempts < 8
       and (e.status in ('failed', 'pending') or (e.status = 'processing' and e.locked_at < now() - interval '15 minutes'))
     order by e.business_date
     limit 1;
    v_date := coalesce(v_date, v_today - 1);
  else
    v_date := p_date;
  end if;

  if v_date is null or v_date >= v_today then
    perform booking._err('invalid_param', 'Kirjauspäivä pitää olla mennyt Helsingin päivä');
  end if;

  -- kaksiosainen lukko on (int4, int4); avain mahtuu int4:ään
  perform pg_advisory_xact_lock(77261018, (v_date - date '2000-01-01')::integer);

  select * into v_row from booking.accounting_exports
   where kind = 'daily_sales' and business_date = v_date
   for update;

  if found and v_row.status = 'sent' then
    return jsonb_build_object('ok', true, 'action', 'already', 'id', v_row.id, 'status', 'sent',
      'business_date', v_date, 'procountor_ledger_id', v_row.procountor_ledger_id, 'environment', v_row.environment);
  end if;
  if found and v_row.status = 'processing' and v_row.locked_at > now() - interval '15 minutes' then
    return jsonb_build_object('ok', true, 'action', 'in_progress', 'id', v_row.id, 'status', 'processing', 'business_date', v_date);
  end if;
  if found and v_row.status = 'failed' and v_row.attempts >= 8 then
    return jsonb_build_object('ok', true, 'action', 'skip', 'reason', 'max_attempts', 'id', v_row.id, 'status', 'failed', 'business_date', v_date);
  end if;

  v_report := booking._report_json(v_date, v_date, false, false);
  v_built := booking._procountor_daily_build(v_date, v_report, v_settings);

  if coalesce((v_built ->> 'empty')::boolean, false) then
    v_status := 'skipped'; v_action := 'skip'; v_err := null;
  elsif coalesce((v_built ->> 'ready')::boolean, false) and v_mode = 'live' and not coalesce(p_force_dry_run, false) then
    v_status := 'processing'; v_action := 'send'; v_err := null;
  elsif not coalesce((v_built ->> 'ready')::boolean, false) then
    v_status := 'needs_review'; v_action := 'skip';
    v_err := 'missing:' || (select string_agg(x, ',') from jsonb_array_elements_text(v_built -> 'missing') x);
  else
    v_status := 'dry_run'; v_action := 'skip';
    v_err := case when coalesce(p_force_dry_run, false) then 'credentials_missing' else null end;
  end if;

  if found then
    update booking.accounting_exports set
      environment = v_env, status = v_status, report = v_report, request = v_built -> 'request',
      last_error = v_err, locked_at = case when v_status = 'processing' then now() else null end
     where id = v_row.id
    returning id into v_id;
  else
    insert into booking.accounting_exports(kind, dedupe_key, business_date, environment, status, report, request, last_error, locked_at)
    values ('daily_sales', 'daily:' || v_date::text, v_date, v_env, v_status, v_report, v_built -> 'request', v_err,
            case when v_status = 'processing' then now() else null end)
    returning id into v_id;
  end if;

  return jsonb_build_object(
    'ok', true, 'action', v_action, 'id', v_id, 'status', v_status, 'business_date', v_date,
    'environment', v_env, 'api_prefix', coalesce(nullif(v_settings ->> 'api_prefix', ''), '/supported/api'),
    'reason', v_err,
    'request', case when v_status in ('processing', 'dry_run', 'needs_review') then v_built -> 'request' else null end);
end $function$;

-- Laskun välityksen varaus. Sama avain ei luo toista lähetystä. Ei lähetä Procountoriin.
create function booking.procountor_invoice_reserve(
  p_key text,
  p_request jsonb,
  p_channel text,
  p_business_date date,
  p_blockers jsonb default '[]'::jsonb,
  p_force_dry_run boolean default false
) returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_key text := btrim(coalesce(p_key, ''));
  v_dedupe text;
  v_mode text;
  v_env text;
  v_status text;
  v_action text;
  v_err text;
  v_row booking.accounting_exports%rowtype;
  v_blockers text;
begin
  if booking._jwt_role() in ('anon', 'authenticated') then
    perform booking._err('forbidden', 'Vain palvelu');
  end if;
  if v_key !~ '^[A-Za-z0-9._:-]{1,120}$' then
    perform booking._err('invalid_param', 'idempotency_key: 1–120 merkkiä [A-Za-z0-9._:-]');
  end if;
  if p_request is null or jsonb_typeof(p_request) <> 'object' then
    perform booking._err('invalid_param', 'request pitää olla objekti');
  end if;
  if p_channel not in ('EMAIL', 'ELECTRONIC_INVOICE') then
    perform booking._err('invalid_param', 'channel: EMAIL|ELECTRONIC_INVOICE');
  end if;
  if p_business_date is null then
    perform booking._err('invalid_param', 'business_date puuttuu');
  end if;
  if p_blockers is not null and jsonb_typeof(p_blockers) <> 'array' then
    perform booking._err('invalid_param', 'blockers pitää olla taulukko');
  end if;

  select c.mode, case when coalesce(c.settings ->> 'environment', 'pts') = 'prod' then 'prod' else 'pts' end
    into v_mode, v_env
    from booking.integration_config c where c.key = 'procountor';
  v_mode := coalesce(v_mode, 'off');
  v_dedupe := 'invoice:' || v_key;
  v_blockers := (select string_agg(x, ',') from jsonb_array_elements_text(coalesce(p_blockers, '[]'::jsonb)) x);

  perform pg_advisory_xact_lock(77261019, hashtext(v_dedupe));
  select * into v_row from booking.accounting_exports where dedupe_key = v_dedupe for update;

  if found and v_row.status = 'sent' then
    return jsonb_build_object('ok', true, 'action', 'already', 'id', v_row.id, 'status', 'sent',
      'invoice_id', v_row.procountor_invoice_id, 'ledger_receipt_id', v_row.procountor_ledger_id,
      'step', v_row.response ->> 'step', 'environment', v_row.environment);
  end if;
  if found and v_row.status = 'processing' and v_row.locked_at > now() - interval '15 minutes' then
    return jsonb_build_object('ok', true, 'action', 'in_progress', 'id', v_row.id, 'status', 'processing');
  end if;

  if coalesce(v_blockers, '') <> '' then
    v_status := 'needs_review'; v_action := 'blocked'; v_err := 'missing:' || v_blockers;
  elsif v_mode = 'live' and not coalesce(p_force_dry_run, false) then
    v_status := 'processing'; v_action := 'send'; v_err := null;
  else
    v_status := 'dry_run'; v_action := 'dry_run';
    v_err := case when coalesce(p_force_dry_run, false) then 'credentials_missing'
                  when v_mode = 'off' then 'mode_off' else null end;
  end if;

  if found then
    update booking.accounting_exports set
      environment = v_env, status = v_status, business_date = p_business_date, request = p_request,
      last_error = v_err, locked_at = case when v_status = 'processing' then now() else null end
     where id = v_row.id;
    v_row.id := v_row.id;
  else
    insert into booking.accounting_exports(kind, dedupe_key, business_date, environment, status, request, last_error, locked_at)
    values ('sales_invoice', v_dedupe, p_business_date, v_env, v_status, p_request, v_err,
            case when v_status = 'processing' then now() else null end)
    returning id into v_row.id;
  end if;

  return jsonb_build_object('ok', true, 'action', v_action, 'id', v_row.id, 'status', v_status,
    'environment', v_env, 'channel', p_channel, 'reason', v_err,
    'step', case when found then v_row.response ->> 'step' else null end,
    'invoice_id', case when found then v_row.procountor_invoice_id else null end,
    'ledger_receipt_id', case when found then v_row.procountor_ledger_id else null end,
    'request', p_request);
end $function$;

create function booking.procountor_export_mark(p_id bigint, p_status text, p_error text default null, p_response jsonb default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_row booking.accounting_exports%rowtype;
  v_resp jsonb := coalesce(p_response, '{}'::jsonb);
  v_inv bigint;
  v_led bigint;
begin
  if booking._jwt_role() in ('anon', 'authenticated') then
    perform booking._err('forbidden', 'Vain palvelu');
  end if;
  if p_status not in ('sent', 'failed', 'dry_run', 'needs_review', 'processing') then
    perform booking._err('invalid_param', 'status: sent|failed|dry_run|needs_review|processing');
  end if;
  if v_resp::text ~* 'client_secret|api_key|access_token|refresh_token|redirect_uri' then
    perform booking._err('invalid_param', 'response ei saa sisältää salaisuutta');
  end if;
  v_resp := v_resp - 'access_token' - 'api_key' - 'client_secret' - 'refresh_token' - 'authorization' - 'redirect_uri';
  select * into v_row from booking.accounting_exports where id = p_id for update;
  if not found then perform booking._err('not_found', 'Vientiä ei löydy'); end if;
  if v_row.status = 'sent' then
    return jsonb_build_object('ok', true, 'already', true, 'id', v_row.id, 'status', 'sent');
  end if;
  if coalesce(v_resp ->> 'invoice_id', '') ~ '^[0-9]+$' then v_inv := (v_resp ->> 'invoice_id')::bigint; end if;
  if coalesce(v_resp ->> 'ledger_receipt_id', '') ~ '^[0-9]+$' then v_led := (v_resp ->> 'ledger_receipt_id')::bigint; end if;
  update booking.accounting_exports set
    status = p_status,
    attempts = case when p_status = 'failed' then attempts + 1 else attempts end,
    last_error = nullif(left(coalesce(p_error, ''), 500), ''),
    response = case when v_resp = '{}'::jsonb then response else v_resp end,
    procountor_invoice_id = coalesce(v_inv, procountor_invoice_id),
    procountor_ledger_id = coalesce(v_led, procountor_ledger_id),
    locked_at = case when p_status = 'processing' then now() else null end,
    sent_at = case when p_status = 'sent' then now() else sent_at end
   where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id, 'status', p_status);
end $function$;

create function booking.admin_procountor_status()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_mode text;
  v_settings jsonb;
  v_last jsonb;
  v_errors jsonb;
  v_accounts boolean;
  v_bank boolean;
begin
  perform booking._require_permission('settings.edit');
  select c.mode, c.settings into v_mode, v_settings from booking.integration_config c where c.key = 'procountor';
  v_settings := coalesce(v_settings, '{}'::jsonb);
  v_accounts := coalesce(v_settings ->> 'vat_status', '') ~ '^[0-9]{1,4}$'
    and exists (
      select 1 from jsonb_each_text(coalesce(v_settings #> '{accounts,sales_by_vat}', '{}'::jsonb)) s
       where btrim(s.value) <> '')
    and exists (
      select 1 from jsonb_each_text(coalesce(v_settings #> '{accounts,clearing_by_method}', '{}'::jsonb)) s
       where btrim(s.value) <> '');
  v_bank := btrim(coalesce(v_settings ->> 'bank_account', '')) <> '';
  select jsonb_build_object(
           'business_date', e.business_date, 'kind', e.kind, 'status', e.status,
           'attempts', e.attempts, 'last_error', e.last_error, 'updated_at', e.updated_at, 'sent_at', e.sent_at,
           'environment', e.environment)
    into v_last
    from booking.accounting_exports e
   order by e.updated_at desc
   limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'business_date', e.business_date, 'kind', e.kind, 'status', e.status,
           'attempts', e.attempts, 'last_error', e.last_error, 'updated_at', e.updated_at)
           order by e.updated_at desc), '[]'::jsonb)
    into v_errors
    from (
      select * from booking.accounting_exports
       where status in ('failed', 'needs_review')
       order by updated_at desc
       limit 8
    ) e;
  return jsonb_build_object(
    'ok', true,
    'mode', coalesce(v_mode, 'off'),
    'environment', case when v_settings ->> 'environment' = 'prod' then 'prod' else 'pts' end,
    'daily_enabled', coalesce(v_settings ->> 'daily_enabled', 'false') = 'true',
    'api_prefix', coalesce(nullif(v_settings ->> 'api_prefix', ''), '/supported/api'),
    'accounts_configured', v_accounts,
    'bank_account_configured', v_bank,
    'last', v_last,
    'errors', coalesce(v_errors, '[]'::jsonb));
end $function$;

comment on function booking._procountor_daily_build(date, jsonb, jsonb) is 'Päiväkirja raportin by_vat/by_method/rounding-kentistä. Ei omaa ALV-laskentaa.';
comment on function booking.procountor_daily_prepare(date, boolean) is 'Palvelu: koostaa eilisen (tai annetun menneen päivän) myyntikirjauksen. Sama päivä = yksi rivi.';
comment on function booking.procountor_invoice_reserve(text, jsonb, text, date, jsonb, boolean) is 'Palvelu: laskun välityksen idempotentti varaus. Sama avain ei lähde kahdesti.';
comment on function booking.procountor_export_mark(bigint, text, text, jsonb) is 'Palvelu: kirjaa lähetyksen tuloksen. processing säilyttää laskun id:n kesken ajon. Ei tallenna salaisuuksia.';
comment on function booking.admin_procountor_status() is 'Asetukset: Procountor-tila ilman salaisuuksia. Oikeus settings.edit.';

do $$ declare r record; begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p
            where p.pronamespace = 'booking'::regnamespace
              and p.proname in ('_procountor_daily_build', 'procountor_daily_prepare', 'procountor_invoice_reserve', 'procountor_export_mark', 'admin_procountor_status')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
    if r.proname = 'admin_procountor_status' then
      execute format('grant execute on function %s to authenticated', r.f);
    end if;
  end loop;
end $$;
