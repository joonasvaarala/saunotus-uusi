-- booking_216: maksuvälittäjän provisio (raportti + säännöt).
-- Ajettu: DEV 20261030111845, PROD 20261030111928 (tiedostonimi = PROD-versio).
--
-- 1) payments.provider_fee ja refunds.provider_fee: välittäjän ilmoittama provisio (EUR).
--    Täydennetään raw-jsonista, kun siinä on tunnistettu kenttä (webhook / API).
-- 2) booking.payment_fee_rules: palvelu + maksutapa, kiinteä € + %. Vain jos toteutunutta ei ole.
-- 3) admin_report_provider_fees: jakso, palvelu, maksutapa, kpl, brutto, provisio, netto.
--    Hyvitykset erikseen. Lähde actual | estimated | missing.
-- Asiakkaan funktioita ei korvata. Kuitti ja kauppa eivät saa välittäjän tuotemerkkiä tästä.
-- Paluu: booking/supabase/rollbacks/20261030111928_booking_216_ROLLBACK.sql

alter table booking.payments add column if not exists provider_fee numeric(12,4);
alter table booking.refunds add column if not exists provider_fee numeric(12,4);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payments_provider_fee_range') then
    alter table booking.payments add constraint payments_provider_fee_range
      check (provider_fee is null or (provider_fee >= -100000 and provider_fee <= 100000));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'refunds_provider_fee_range') then
    alter table booking.refunds add constraint refunds_provider_fee_range
      check (provider_fee is null or (provider_fee >= -100000 and provider_fee <= 100000));
  end if;
end $$;

comment on column booking.payments.provider_fee is 'booking_216: välittäjän ilmoittama provisio euroina. Null = ei ilmoitettu, raportti käyttää sääntöä tai merkitsee puuttuvaksi.';
comment on column booking.refunds.provider_fee is 'booking_216: hyvityksen provisio euroina välittäjän ilmoituksesta. Null = ei ilmoitettu.';

create table if not exists booking.payment_fee_rules (
  id          bigint generated always as identity primary key,
  provider    text not null,
  method      text not null default '*',
  fixed_eur   numeric(12,4) not null default 0,
  percent     numeric(7,4) not null default 0,
  active      boolean not null default true,
  updated_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint payment_fee_rules_provider_chk check (provider ~ '^[a-z][a-z0-9_]{0,39}$'),
  constraint payment_fee_rules_method_chk check (method ~ '^(\*|[a-z][a-z0-9_]{0,39})$'),
  constraint payment_fee_rules_fixed_chk check (fixed_eur >= 0 and fixed_eur <= 1000),
  constraint payment_fee_rules_percent_chk check (percent >= 0 and percent <= 100),
  constraint payment_fee_rules_provider_method_uq unique (provider, method)
);

comment on table booking.payment_fee_rules is 'booking_216: provisiosääntö, kun välittäjä ei ilmoittanut summaa. method=* koskee palvelun kaikkia maksutapoja. Tarkempi sääntö voittaa.';

drop trigger if exists payment_fee_rules_updated on booking.payment_fee_rules;
create trigger payment_fee_rules_updated before update on booking.payment_fee_rules
  for each row execute function booking.set_updated_at();

create or replace function booking._json_num(p jsonb)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare t text;
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if jsonb_typeof(p) = 'number' then return (p #>> '{}')::numeric; end if;
  if jsonb_typeof(p) = 'string' then
    t := replace(btrim(p #>> '{}'), ',', '.');
    if t ~ '^-?[0-9]+(\.[0-9]+)?$' then return t::numeric; end if;
  end if;
  return null;
end $$;

-- Ensimmäinen tunnistettu kenttä. Juuren amount ei ole provisio. Sisäkkäinen fees/settlement/pricing saa käyttää amount/total/value.
create or replace function booking._extract_provider_fee(p_raw jsonb)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  euro text[] := array['provider_fee','providerFee','merchantFee','merchant_fee','feeAmount','fee_amount','commissionAmount','commission_amount','commission','provision','serviceFee','service_fee','paymentFee','payment_fee','fee'];
  cent text[] := array['feeCents','fee_cents','merchantFeeCents','merchant_fee_cents','commissionCents','commission_cents'];
  nests text[] := array['fees','settlement','pricing','merchantFees','merchant_fees'];
  euro_n text[] := euro || array['amount','total','value'];
  cent_n text[] := cent || array['amount_cents','amountCents'];
  k text; n text; v numeric; obj jsonb;
begin
  if p_raw is null or jsonb_typeof(p_raw) <> 'object' then return null; end if;
  foreach k in array euro loop
    v := booking._json_num(p_raw -> k);
    if v is not null then return round(v, 4); end if;
  end loop;
  foreach k in array cent loop
    v := booking._json_num(p_raw -> k);
    if v is not null then return round(v / 100, 4); end if;
  end loop;
  foreach n in array nests loop
    obj := p_raw -> n;
    if jsonb_typeof(obj) is distinct from 'object' then continue; end if;
    foreach k in array euro_n loop
      v := booking._json_num(obj -> k);
      if v is not null then return round(v, 4); end if;
    end loop;
    foreach k in array cent_n loop
      v := booking._json_num(obj -> k);
      if v is not null then return round(v / 100, 4); end if;
    end loop;
  end loop;
  return null;
end $$;

create or replace function booking._stamp_provider_fee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v numeric;
begin
  v := booking._extract_provider_fee(new.raw);
  if v is not null then new.provider_fee := v; end if;
  return new;
end $$;

drop trigger if exists payments_provider_fee on booking.payments;
create trigger payments_provider_fee before insert or update of raw on booking.payments
  for each row execute function booking._stamp_provider_fee();

drop trigger if exists refunds_provider_fee on booking.refunds;
create trigger refunds_provider_fee before insert or update of raw on booking.refunds
  for each row execute function booking._stamp_provider_fee();

update booking.payments
   set provider_fee = booking._extract_provider_fee(raw)
 where raw is not null and booking._extract_provider_fee(raw) is not null
   and provider_fee is distinct from booking._extract_provider_fee(raw);

update booking.refunds
   set provider_fee = booking._extract_provider_fee(raw)
 where raw is not null and booking._extract_provider_fee(raw) is not null
   and provider_fee is distinct from booking._extract_provider_fee(raw);

create or replace function booking._provider_admin_label(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p
    when 'montonio' then 'Montonio'
    when 'visma_pay' then 'Visma Pay'
    when 'mobilepay' then 'MobilePay'
    when 'manual' then 'Käsin'
    when 'johku' then 'Johku'
    else coalesce(p, '')
  end
$$;

create index if not exists payments_fee_paid_idx on booking.payments (paid_at)
  where status in ('paid', 'partially_refunded', 'refunded');
create index if not exists refunds_fee_done_idx on booking.refunds (done_at) where status = 'done';

create or replace function booking.admin_report_provider_fees(p_from date, p_to date, p_format text default 'json')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rep jsonb; v_body text := ''; v_cr text := E'\r\n';
begin
  perform booking._require_permission('reports.view');
  if p_from is null or p_to is null or p_to < p_from or (p_to - p_from) > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  if coalesce(p_format, 'json') not in ('json', 'csv') then
    perform booking._err('invalid_param', 'Tuntematon muoto');
  end if;

  with lines as (
    select 'sale'::text as direction, p.provider, p.method, pm.label as method_label, p.amount as gross,
           case when p.provider_fee is not null then 'actual' when rule.id is not null then 'estimated' else 'missing' end as basis,
           case when p.provider_fee is not null then round(p.provider_fee, 2)
                when rule.id is not null then round(rule.fixed_eur + p.amount * rule.percent / 100, 2)
                else null end as fee
      from booking.payments p
      left join booking.payment_methods pm on pm.code = p.method
      left join lateral (
        select f.id, f.fixed_eur, f.percent
          from booking.payment_fee_rules f
         where f.active and f.provider = p.provider and (f.method = p.method or f.method = '*')
         order by case when f.method = p.method then 0 else 1 end, f.id
         limit 1
      ) rule on true
     where p.status in ('paid', 'partially_refunded', 'refunded')
       and p.paid_at is not null
       and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
    union all
    select 'refund', p.provider, p.method, pm.label, f.amount,
           case when f.provider_fee is not null then 'actual' when rule.id is not null then 'estimated' else 'missing' end,
           case when f.provider_fee is not null then round(f.provider_fee, 2)
                when rule.id is not null then round(rule.fixed_eur + f.amount * rule.percent / 100, 2)
                else null end
      from booking.refunds f
      join booking.payments p on p.id = f.payment_id
      left join booking.payment_methods pm on pm.code = p.method
      left join lateral (
        select r.id, r.fixed_eur, r.percent
          from booking.payment_fee_rules r
         where r.active and r.provider = p.provider and (r.method = p.method or r.method = '*')
         order by case when r.method = p.method then 0 else 1 end, r.id
         limit 1
      ) rule on true
     where f.status = 'done' and f.done_at is not null
       and (f.done_at at time zone 'Europe/Helsinki')::date between p_from and p_to
  ),
  agg as (
    select direction, provider, method, max(method_label) as method_label, basis,
           count(*)::int as n,
           round(sum(gross), 2) as gross,
           case when bool_or(fee is null) then null else round(sum(fee), 2) end as fee
      from lines
     group by direction, provider, method, basis
  ),
  tot as (
    select
      count(*) filter (where direction = 'sale')::int as sales_count,
      coalesce(round(sum(gross) filter (where direction = 'sale'), 2), 0) as sales_gross,
      count(*) filter (where direction = 'sale' and fee is null)::int as sales_missing,
      coalesce(round(sum(fee) filter (where direction = 'sale'), 2), 0) as sales_fee_sum,
      count(*) filter (where direction = 'refund')::int as refund_count,
      coalesce(round(sum(gross) filter (where direction = 'refund'), 2), 0) as refund_gross,
      count(*) filter (where direction = 'refund' and fee is null)::int as refund_missing,
      coalesce(round(sum(fee) filter (where direction = 'refund'), 2), 0) as refund_fee_sum
    from lines
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'kind', 'range'),
    'timezone', 'Europe/Helsinki',
    'basis', 'paid_at',
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'provider', a.provider,
               'provider_label', booking._provider_admin_label(a.provider),
               'method', a.method,
               'method_label', coalesce(a.method_label, a.method),
               'direction', a.direction,
               'basis', a.basis,
               'count', a.n,
               'gross', a.gross,
               'fee', a.fee,
               'net', case when a.fee is null then null
                           when a.direction = 'sale' then round(a.gross - a.fee, 2)
                           else round(-(a.gross + a.fee), 2) end)
             order by case a.direction when 'sale' then 0 else 1 end, a.provider, a.method,
                      case a.basis when 'actual' then 0 when 'estimated' then 1 else 2 end)
        from agg a), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'sales_count', t.sales_count,
        'sales_gross', t.sales_gross,
        'sales_fee', case when t.sales_missing > 0 then null else t.sales_fee_sum end,
        'sales_net', case when t.sales_missing > 0 then null else round(t.sales_gross - t.sales_fee_sum, 2) end,
        'refund_count', t.refund_count,
        'refund_gross', t.refund_gross,
        'refund_fee', case when t.refund_missing > 0 then null else t.refund_fee_sum end,
        'refund_net', case when t.refund_missing > 0 then null else round(-(t.refund_gross + t.refund_fee_sum), 2) end,
        'settlement', case when t.sales_missing > 0 or t.refund_missing > 0 then null
                           else round((t.sales_gross - t.sales_fee_sum) - (t.refund_gross + t.refund_fee_sum), 2) end,
        'missing', t.sales_missing + t.refund_missing)
      from tot t)
  ) into v_rep;

  if p_format = 'json' then return v_rep; end if;

  select coalesce((
    select string_agg(concat_ws(';',
             booking._csv(x ->> 'provider_label'),
             booking._csv(x ->> 'method_label'),
             case x ->> 'direction' when 'refund' then 'hyvitys' else 'maksu' end,
             case x ->> 'basis' when 'actual' then 'toteutunut' when 'estimated' then 'arvio' else 'puuttuu' end,
             coalesce(x ->> 'count', '0'),
             booking._csvmoney(coalesce((x ->> 'gross')::numeric, 0)),
             case when x ->> 'fee' is null then '' else booking._csvmoney((x ->> 'fee')::numeric) end,
             case when x ->> 'net' is null then '' else booking._csvmoney((x ->> 'net')::numeric) end),
           v_cr order by t.n) || v_cr
      from jsonb_array_elements(v_rep -> 'rows') with ordinality as t(x, n)
  ), '') into v_body;
  return jsonb_build_object(
    'filename', format('provisio_%s_%s.csv', p_from, p_to),
    'mime', 'text/csv;charset=utf-8',
    'content', chr(65279) || 'palvelu;maksutapa;laji;lahde;kpl;brutto;provisio;netto' || v_cr || v_body);
end $$;

create or replace function booking.admin_list_payment_fee_rules()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  perform booking._require_permission('settings.edit');
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'provider', f.provider, 'provider_label', booking._provider_admin_label(f.provider),
           'method', f.method, 'fixed_eur', f.fixed_eur, 'percent', f.percent, 'active', f.active)
         order by f.provider, f.method), '[]'::jsonb)
    into v
    from booking.payment_fee_rules f;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function booking.admin_upsert_payment_fee_rule(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_provider text := lower(btrim(coalesce(p ->> 'provider', '')));
  v_method text := lower(btrim(coalesce(p ->> 'method', '*')));
  v_fixed numeric; v_percent numeric; v_active boolean; row booking.payment_fee_rules;
begin
  perform booking._require_permission('settings.edit');
  if v_method = '' then v_method := '*'; end if;
  if v_provider !~ '^[a-z][a-z0-9_]{0,39}$' or v_method !~ '^(\*|[a-z][a-z0-9_]{0,39})$' then
    perform booking._err('invalid_value', 'Tarkista palvelu ja maksutapa');
  end if;
  begin
    v_fixed := replace(btrim(coalesce(p ->> 'fixed_eur', '')), ',', '.')::numeric;
    v_percent := replace(btrim(coalesce(p ->> 'percent', '')), ',', '.')::numeric;
  exception when others then
    perform booking._err('invalid_value', 'Tarkista kiinteä summa ja prosentti');
  end;
  if v_fixed is null or v_percent is null or v_fixed < 0 or v_fixed > 1000 or v_percent < 0 or v_percent > 100 then
    perform booking._err('invalid_value', 'Tarkista kiinteä summa ja prosentti');
  end if;
  v_active := case when p ? 'active' and jsonb_typeof(p -> 'active') = 'boolean' then (p ->> 'active')::boolean else true end;
  insert into booking.payment_fee_rules(provider, method, fixed_eur, percent, active, updated_by)
  values (v_provider, v_method, round(v_fixed, 4), round(v_percent, 4), v_active, auth.uid())
  on conflict (provider, method) do update
    set fixed_eur = excluded.fixed_eur, percent = excluded.percent, active = excluded.active, updated_by = excluded.updated_by
  returning * into row;
  return jsonb_build_object('ok', true, 'rule', jsonb_build_object(
    'id', row.id, 'provider', row.provider, 'provider_label', booking._provider_admin_label(row.provider),
    'method', row.method, 'fixed_eur', row.fixed_eur, 'percent', row.percent, 'active', row.active));
end $$;

create or replace function booking.admin_delete_payment_fee_rule(p_id bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare n int;
begin
  perform booking._require_permission('settings.edit');
  delete from booking.payment_fee_rules where id = p_id;
  get diagnostics n = row_count;
  if n = 0 then perform booking._err('not_found', 'Sääntöä ei löydy'); end if;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function booking._json_num(jsonb) from public, anon, authenticated;
revoke all on function booking._extract_provider_fee(jsonb) from public, anon, authenticated;
revoke all on function booking._stamp_provider_fee() from public, anon, authenticated;
revoke all on function booking._provider_admin_label(text) from public, anon, authenticated;
revoke all on function booking.admin_report_provider_fees(date, date, text) from public, anon;
revoke all on function booking.admin_list_payment_fee_rules() from public, anon;
revoke all on function booking.admin_upsert_payment_fee_rule(jsonb) from public, anon;
revoke all on function booking.admin_delete_payment_fee_rule(bigint) from public, anon;
grant execute on function booking._json_num(jsonb) to service_role;
grant execute on function booking._extract_provider_fee(jsonb) to service_role;
grant execute on function booking._stamp_provider_fee() to service_role;
grant execute on function booking._provider_admin_label(text) to service_role;
grant execute on function booking.admin_report_provider_fees(date, date, text) to authenticated, service_role;
grant execute on function booking.admin_list_payment_fee_rules() to authenticated, service_role;
grant execute on function booking.admin_upsert_payment_fee_rule(jsonb) to authenticated, service_role;
grant execute on function booking.admin_delete_payment_fee_rule(bigint) to authenticated, service_role;

alter table booking.payment_fee_rules enable row level security;
revoke all on table booking.payment_fee_rules from public, anon, authenticated;
grant select on table booking.payment_fee_rules to authenticated;
grant all on table booking.payment_fee_rules to service_role;
grant usage, select on sequence booking.payment_fee_rules_id_seq to service_role;
drop policy if exists staff_read on booking.payment_fee_rules;
create policy staff_read on booking.payment_fee_rules for select to authenticated using ((select booking.is_staff()));

do $$ begin
  perform booking._add_audit('booking.payment_fee_rules');
exception when duplicate_object then null;
end $$;

comment on function booking.admin_report_provider_fees(date, date, text) is 'booking_216: provisioraportti palveluittain ja maksutavoittain. Vain reports.view. JSON tai CSV (puolipiste, suomalainen desimaali). Hyvitykset erikseen.';
comment on function booking.admin_list_payment_fee_rules() is 'booking_216: provisiosäännöt. Vain settings.edit.';
comment on function booking.admin_upsert_payment_fee_rule(jsonb) is 'booking_216: tallenna provisiosääntö (provider, method, fixed_eur, percent, active). Vain settings.edit.';
comment on function booking.admin_delete_payment_fee_rule(bigint) is 'booking_216: poista provisiosääntö. Vain settings.edit.';
