-- booking_349: maksunvälittäjän tilitykset (K9). KirjanpitoTapion marraskuun tarkastus (Joonas 24.11.2026).
-- * booking.settlements (erä, päivä, brutto, kulu, netto, maksujen määrä) + settlement_items (rivit, kohdistus maksuun/hyvitykseen).
-- * CSV-tuonti (Saunotus-tilitys-CSV v1, booking/docs/tilitys-csv.md): admin_import_settlement_csv (settings.edit + reports.view) / svc_import_settlement_csv (service_role).
--   Oletus p_dry_run = true. Kohdistetun maksun/hyvityksen provider_fee täytetään, jos tyhjä; eri arvoa ei ylikirjoiteta ilman p_overwrite_fees.
-- * Kulutili luetaan asetuksesta accounts.provider_fee (Procountor-asetukset) ja tallennetaan erälle; kuluja EI kirjata (posted = false). Ei Procountor-kutsuja.
-- Edellyttää booking_347:ää (admin_get/set_procountor_settings). Rollback: booking/supabase/rollbacks/20261125000500_booking_349_ROLLBACK.sql.
do $pre$
begin
  if md5(pg_get_functiondef('booking.admin_get_procountor_settings()'::regprocedure)) <> '2e1f7ba1525cbb77e05a97fbde0820af'
     or md5(pg_get_functiondef('booking.admin_set_procountor_settings(jsonb)'::regprocedure)) <> '519c6c521cb9faa686b61ebcc3d04929' then
    raise exception 'booking_349 edellyttää booking_347:ää (admin_get/set_procountor_settings)';
  end if;
end $pre$;
create table if not exists booking.settlements (
  id bigint generated always as identity primary key,
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  batch_ref text not null check (char_length(batch_ref) between 1 and 100),
  settled_on date not null,
  currency text not null default 'EUR' check (currency = 'EUR'),
  gross numeric(12,2) not null,
  fee numeric(12,2) not null,
  net numeric(12,2) not null,
  payment_count integer not null default 0,
  refund_count integer not null default 0,
  other_count integer not null default 0,
  matched_count integer not null default 0,
  unmatched_count integer not null default 0,
  fee_account text,
  posted boolean not null default false,
  source text not null default 'csv' check (source = 'csv'),
  source_filename text check (source_filename is null or char_length(source_filename) <= 200),
  source_md5 text not null,
  imported_by uuid,
  imported_actor text,
  imported_at timestamptz not null default now(),
  constraint settlements_net_chk check (abs(net - (gross - fee)) <= 0.01),
  constraint settlements_batch_key unique (provider, batch_ref)
);
comment on table booking.settlements is 'booking_349 (K9): maksunvälittäjän tilityserät (CSV-tuonti). fee_account = asetus accounts.provider_fee tuontihetkellä; kuluja ei vielä kirjata (posted = false).';
create table if not exists booking.settlement_items (
  id bigint generated always as identity primary key,
  settlement_id bigint not null references booking.settlements(id) on delete restrict,
  line_no integer not null,
  kind text not null check (kind in ('payment', 'refund', 'fee', 'adjustment')),
  reference text check (reference is null or char_length(reference) <= 200),
  payment_id bigint references booking.payments(id) on delete restrict,
  refund_id bigint references booking.refunds(id) on delete restrict,
  gross numeric(12,2) not null,
  fee numeric(12,2) not null,
  net numeric(12,2) not null,
  match_status text not null check (match_status in ('matched', 'unmatched', 'ambiguous', 'not_applicable')),
  fee_applied text check (fee_applied in ('set', 'same', 'conflict', 'overwritten')),
  raw jsonb not null,
  constraint settlement_items_line_key unique (settlement_id, line_no)
);
create index if not exists settlement_items_payment_idx on booking.settlement_items (payment_id) where payment_id is not null;
create index if not exists settlement_items_refund_idx on booking.settlement_items (refund_id) where refund_id is not null;
create index if not exists settlements_settled_on_idx on booking.settlements (settled_on);
alter table booking.settlements enable row level security;
alter table booking.settlement_items enable row level security;
revoke all on booking.settlements, booking.settlement_items from public, anon, authenticated;

-- Desimaaliluku CSV:stä: "1 234,56", "1234.56", "-12,5", "€" ja välilyönnit sallitaan. Tyhjä → null. Kelvoton → virhe.
CREATE OR REPLACE FUNCTION booking._settlement_num(p text)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare s text := replace(replace(replace(replace(btrim(coalesce(p, '')), ' ', ''), chr(160), ''), '€', ''), 'EUR', '');
begin
  if s = '' then return null; end if;
  if s ~ '^-?\d{1,3}(\.\d{3})+,\d{1,4}$' then s := replace(replace(s, '.', ''), ',', '.');      -- 1.234,56
  elsif s ~ '^-?\d{1,3}(,\d{3})+\.\d{1,4}$' then s := replace(s, ',', '');                     -- 1,234.56
  elsif s ~ '^-?\d+,\d{1,4}$' then s := replace(s, ',', '.');
  end if;
  if s !~ '^-?\d{1,9}(\.\d{1,4})?$' then perform booking._err('settlement_csv_invalid', format('Luku ei kelpaa: %s', left(p, 40))); end if;
  return s::numeric;
end $function$;

-- CSV → rivit (jsonb-taulukko objekteja, avaimet normalisoituina). Muoto: booking/docs/tilitys-csv.md (Saunotus-tilitys-CSV v1).
CREATE OR REPLACE FUNCTION booking._settlement_parse_csv(p_csv text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare v_text text; v_lines text[]; v_delim text; v_hdr text[]; v_cols text[] := '{}'; v_rows jsonb := '[]'::jsonb; v_f text[]; v_obj jsonb; i int; j int; c text; m text[]; v_line text;
        v_alias jsonb := '{"erä":"batch","era":"batch","batch":"batch","batch_id":"batch","batch_ref":"batch","settlement_id":"batch","payout_id":"batch",
                           "päivä":"date","paiva":"date","pvm":"date","date":"date","settled_on":"date","settlement_date":"date","payout_date":"date",
                           "laji":"type","tyyppi":"type","type":"type",
                           "viite":"reference","reference":"reference","ref":"reference","merchant_reference":"reference","order_reference":"reference","transaction_id":"reference",
                           "maksu_id":"payment_id","payment_id":"payment_id",
                           "brutto":"gross","gross":"gross","amount":"gross",
                           "kulu":"fee","palkkio":"fee","provisio":"fee","fee":"fee","fees":"fee",
                           "netto":"net","net":"net",
                           "valuutta":"currency","currency":"currency"}'::jsonb;
begin
  if p_csv is null or btrim(p_csv) = '' then perform booking._err('settlement_csv_invalid', 'Tiedosto on tyhjä'); end if;
  if octet_length(p_csv) > 1048576 then perform booking._err('settlement_csv_invalid', 'Tiedosto on yli 1 Mt'); end if;
  v_text := replace(replace(p_csv, chr(65279), ''), E'\r\n', E'\n');
  v_text := replace(v_text, E'\r', E'\n');
  v_lines := array(select x from unnest(string_to_array(v_text, E'\n')) x where btrim(x) <> '');
  if cardinality(v_lines) < 2 then perform booking._err('settlement_csv_invalid', 'Otsikkorivi ja vähintään yksi rivi tarvitaan'); end if;
  if cardinality(v_lines) > 5001 then perform booking._err('settlement_csv_invalid', 'Enintään 5000 riviä'); end if;
  v_delim := case when position(';' in v_lines[1]) > 0 then ';' when position(E'\t' in v_lines[1]) > 0 then E'\t' else ',' end;
  for i in 1 .. cardinality(v_lines) loop
    v_line := v_lines[i];
    v_f := '{}';
    for m in select regexp_matches(v_delim || v_line, '\' || v_delim || '("(?:[^"]|"")*"|[^' || v_delim || ']*)', 'g') loop
      c := m[1];
      if c ~ '^".*"$' then c := replace(substr(c, 2, char_length(c) - 2), '""', '"'); end if;
      v_f := v_f || btrim(c);
    end loop;
    if i = 1 then
      v_hdr := v_f;
      foreach c in array v_hdr loop
        v_cols := v_cols || coalesce(v_alias ->> lower(btrim(c)), '');
      end loop;
      if not (v_cols @> array['batch', 'date', 'type', 'gross', 'fee']) then
        perform booking._err('settlement_csv_invalid', 'Otsikosta puuttuu pakollinen sarake (erä, päivä, laji, brutto, kulu)');
      end if;
      if (select count(*) from unnest(v_cols) x where x <> '') <> (select count(distinct x) from unnest(v_cols) x where x <> '') then
        perform booking._err('settlement_csv_invalid', 'Sama sarake otsikossa kahdesti');
      end if;
      continue;
    end if;
    if cardinality(v_f) <> cardinality(v_cols) then
      perform booking._err('settlement_csv_invalid', format('Rivi %s: sarakkeita %s, otsikossa %s', i, cardinality(v_f), cardinality(v_cols)));
    end if;
    v_obj := jsonb_build_object('line_no', i);
    for j in 1 .. cardinality(v_cols) loop
      if v_cols[j] <> '' then v_obj := v_obj || jsonb_build_object(v_cols[j], v_f[j]); end if;
    end loop;
    v_rows := v_rows || jsonb_build_array(v_obj);
  end loop;
  return v_rows;
end $function$;

-- Tuonti. p_dry_run = true → vain esikatselu. Kaikki tai ei mitään: yksikin virhe kumoaa koko tuonnin.
CREATE OR REPLACE FUNCTION booking._settlement_import(p_provider text, p_csv text, p_filename text, p_dry_run boolean, p_overwrite_fees boolean, p_actor text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_rows jsonb; r jsonb; v_items jsonb := '[]'::jsonb; v_batch text; v_date date; v_type text; v_ref text; v_gross numeric; v_fee numeric; v_net numeric; v_pid bigint; v_rid bigint;
        v_status text; v_n int; v_fee_acct text; v_md5 text; v_res jsonb; b record; v_sid bigint; it jsonb; v_applied text; v_cur numeric; v_batches jsonb := '[]'::jsonb;
        v_errors jsonb := '[]'::jsonb;
begin
  if p_provider is null or p_provider !~ '^[a-z][a-z0-9_]{1,30}$' then perform booking._err('invalid_param', 'Maksunvälittäjä puuttuu'); end if;
  if p_provider in ('manual') then perform booking._err('invalid_param', 'Käsin kirjatuilla maksuilla ei ole tilityksiä'); end if;
  v_md5 := md5(coalesce(p_csv, ''));
  v_rows := booking._settlement_parse_csv(p_csv);
  v_fee_acct := nullif(btrim(coalesce((select c.settings #>> '{accounts,provider_fee}' from booking.integration_config c where c.key = 'procountor'), '')), '');
  for r in select * from jsonb_array_elements(v_rows) loop
    v_batch := btrim(coalesce(r ->> 'batch', ''));
    if v_batch = '' or char_length(v_batch) > 100 then perform booking._err('settlement_csv_invalid', format('Rivi %s: erä puuttuu', r ->> 'line_no')); end if;
    begin
      v_date := case when coalesce(r ->> 'date', '') ~ '^\d{4}-\d{2}-\d{2}' then left(r ->> 'date', 10)::date
                     when coalesce(r ->> 'date', '') ~ '^\d{1,2}\.\d{1,2}\.\d{4}$' then to_date(r ->> 'date', 'DD.MM.YYYY') end;
    exception when others then v_date := null;
    end;
    if v_date is null or v_date > (now() at time zone 'Europe/Helsinki')::date + 1 or v_date < date '2020-01-01' then
      perform booking._err('settlement_csv_invalid', format('Rivi %s: päivä ei kelpaa (%s)', r ->> 'line_no', left(coalesce(r ->> 'date', ''), 20)));
    end if;
    v_type := case lower(btrim(coalesce(r ->> 'type', '')))
                when 'payment' then 'payment' when 'maksu' then 'payment' when 'sale' then 'payment' when 'myynti' then 'payment'
                when 'refund' then 'refund' when 'hyvitys' then 'refund'
                when 'fee' then 'fee' when 'kulu' then 'fee' when 'palkkio' then 'fee'
                when 'adjustment' then 'adjustment' when 'oikaisu' then 'adjustment' when 'korjaus' then 'adjustment' end;
    if v_type is null then perform booking._err('settlement_csv_invalid', format('Rivi %s: tuntematon laji (%s)', r ->> 'line_no', left(coalesce(r ->> 'type', ''), 20))); end if;
    if coalesce(nullif(upper(btrim(coalesce(r ->> 'currency', ''))), ''), 'EUR') <> 'EUR' then perform booking._err('settlement_csv_invalid', format('Rivi %s: vain EUR', r ->> 'line_no')); end if;
    v_gross := coalesce(booking._settlement_num(r ->> 'gross'), 0);
    v_fee := coalesce(booking._settlement_num(r ->> 'fee'), 0);
    v_net := booking._settlement_num(r ->> 'net');
    if v_net is null then v_net := v_gross - v_fee; end if;
    if abs(v_net - (v_gross - v_fee)) > 0.01 then perform booking._err('settlement_csv_invalid', format('Rivi %s: netto ≠ brutto − kulu', r ->> 'line_no')); end if;
    if v_type = 'payment' and v_gross < 0 then perform booking._err('settlement_csv_invalid', format('Rivi %s: maksun brutto on positiivinen', r ->> 'line_no')); end if;
    if v_type = 'refund' and v_gross > 0 then perform booking._err('settlement_csv_invalid', format('Rivi %s: hyvityksen brutto on negatiivinen', r ->> 'line_no')); end if;
    v_ref := nullif(left(btrim(coalesce(r ->> 'reference', '')), 200), '');
    v_pid := null; v_rid := null; v_status := 'not_applicable';
    if v_type = 'payment' then
      if coalesce(r ->> 'payment_id', '') ~ '^\d{1,12}$' then
        select count(*), min(p.id) into v_n, v_pid from booking.payments p where p.id = (r ->> 'payment_id')::bigint and p.provider = p_provider;
      elsif v_ref is not null then
        select count(*), min(p.id) into v_n, v_pid from booking.payments p
         where p.provider = p_provider and (p.provider_ref = v_ref or p.raw ->> 'order_uuid' = v_ref or p.raw ->> 'uuid' = v_ref or p.external_id = v_ref);
      else v_n := 0;
      end if;
      v_status := case when v_n = 1 then 'matched' when v_n > 1 then 'ambiguous' else 'unmatched' end;
      if v_n <> 1 then v_pid := null; end if;
    elsif v_type = 'refund' then
      if v_ref is not null then
        select count(*), min(f.id) into v_n, v_rid from booking.refunds f join booking.payments p on p.id = f.payment_id
         where p.provider = p_provider and f.provider_refund_id = v_ref;
      else v_n := 0;
      end if;
      v_status := case when v_n = 1 then 'matched' when v_n > 1 then 'ambiguous' else 'unmatched' end;
      if v_n <> 1 then v_rid := null; end if;
    end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('line_no', (r ->> 'line_no')::int, 'batch', v_batch, 'date', v_date, 'kind', v_type, 'reference', v_ref,
      'payment_id', v_pid, 'refund_id', v_rid, 'gross', round(v_gross, 2), 'fee', round(v_fee, 2), 'net', round(v_net, 2), 'match_status', v_status, 'raw', r));
  end loop;
  -- erät
  for b in
    select x ->> 'batch' as batch, min((x ->> 'date')::date) as d1, max((x ->> 'date')::date) as d2,
           sum((x ->> 'gross')::numeric) as gross, sum((x ->> 'fee')::numeric) as fee, sum((x ->> 'net')::numeric) as net,
           count(*) filter (where x ->> 'kind' = 'payment') as pc, count(*) filter (where x ->> 'kind' = 'refund') as rc,
           count(*) filter (where x ->> 'kind' in ('fee', 'adjustment')) as oc,
           count(*) filter (where x ->> 'match_status' = 'matched') as mc, count(*) filter (where x ->> 'match_status' in ('unmatched', 'ambiguous')) as uc
      from jsonb_array_elements(v_items) x group by 1 order by 1
  loop
    if b.d1 <> b.d2 then perform booking._err('settlement_csv_invalid', format('Erän %s rivit ovat eri päiviltä', b.batch)); end if;
    if exists (select 1 from booking.settlements s where s.provider = p_provider and s.batch_ref = b.batch) then
      v_errors := v_errors || to_jsonb(b.batch);
    end if;
    v_batches := v_batches || jsonb_build_array(jsonb_build_object('batch', b.batch, 'settled_on', b.d1, 'gross', round(b.gross, 2), 'fee', round(b.fee, 2), 'net', round(b.net, 2),
      'payments', b.pc, 'refunds', b.rc, 'other', b.oc, 'matched', b.mc, 'unmatched', b.uc));
  end loop;
  if jsonb_array_length(v_errors) > 0 then
    perform booking._err('settlement_exists', format('Erä on jo tuotu: %s', (select string_agg(x, ', ') from jsonb_array_elements_text(v_errors) x)));
  end if;
  -- maksukohtaiset kulut: sama maksu ei saa esiintyä kahdesti tiedostossa
  if exists (select 1 from jsonb_array_elements(v_items) x where x ->> 'payment_id' is not null group by x ->> 'payment_id' having count(*) > 1) then
    perform booking._err('settlement_csv_invalid', 'Sama maksu on tiedostossa useammin kuin kerran');
  end if;
  v_res := jsonb_build_object('provider', p_provider, 'dry_run', p_dry_run, 'filename', p_filename, 'rows', jsonb_array_length(v_items), 'batches', v_batches,
    'fee_account', v_fee_acct, 'fee_account_missing', v_fee_acct is null, 'fee_posting', 'not_posted',
    'unmatched', coalesce((select jsonb_agg(jsonb_build_object('line_no', x -> 'line_no', 'kind', x -> 'kind', 'reference', x -> 'reference', 'gross', x -> 'gross', 'match_status', x -> 'match_status'))
                             from jsonb_array_elements(v_items) x where x ->> 'match_status' in ('unmatched', 'ambiguous')), '[]'::jsonb),
    'fee_conflicts', coalesce((select jsonb_agg(jsonb_build_object('line_no', x -> 'line_no', 'payment_id', x -> 'payment_id', 'refund_id', x -> 'refund_id', 'fee', x -> 'fee', 'current', coalesce(p.provider_fee, f.provider_fee)))
                                 from jsonb_array_elements(v_items) x
                                 left join booking.payments p on p.id = (x ->> 'payment_id')::bigint
                                 left join booking.refunds f on f.id = (x ->> 'refund_id')::bigint
                                where coalesce(p.provider_fee, f.provider_fee) is not null and round(coalesce(p.provider_fee, f.provider_fee), 2) <> (x ->> 'fee')::numeric), '[]'::jsonb));
  if p_dry_run then return v_res; end if;
  for b in select x as j from jsonb_array_elements(v_batches) x loop
    insert into booking.settlements(provider, batch_ref, settled_on, gross, fee, net, payment_count, refund_count, other_count, matched_count, unmatched_count,
                                    fee_account, source_filename, source_md5, imported_by, imported_actor)
    values (p_provider, b.j ->> 'batch', (b.j ->> 'settled_on')::date, (b.j ->> 'gross')::numeric, (b.j ->> 'fee')::numeric, (b.j ->> 'net')::numeric,
            (b.j ->> 'payments')::int, (b.j ->> 'refunds')::int, (b.j ->> 'other')::int, (b.j ->> 'matched')::int, (b.j ->> 'unmatched')::int,
            v_fee_acct, left(p_filename, 200), v_md5, auth.uid(), p_actor)
    returning id into v_sid;
    for it in select x from jsonb_array_elements(v_items) x where x ->> 'batch' = b.j ->> 'batch' order by (x ->> 'line_no')::int loop
      v_applied := null;
      if it ->> 'payment_id' is not null then
        select p.provider_fee into v_cur from booking.payments p where p.id = (it ->> 'payment_id')::bigint for update;
        if v_cur is null then update booking.payments set provider_fee = (it ->> 'fee')::numeric where id = (it ->> 'payment_id')::bigint; v_applied := 'set';
        elsif round(v_cur, 2) = (it ->> 'fee')::numeric then v_applied := 'same';
        elsif p_overwrite_fees then update booking.payments set provider_fee = (it ->> 'fee')::numeric where id = (it ->> 'payment_id')::bigint; v_applied := 'overwritten';
        else v_applied := 'conflict';
        end if;
      elsif it ->> 'refund_id' is not null then
        select f.provider_fee into v_cur from booking.refunds f where f.id = (it ->> 'refund_id')::bigint for update;
        if v_cur is null then update booking.refunds set provider_fee = (it ->> 'fee')::numeric where id = (it ->> 'refund_id')::bigint; v_applied := 'set';
        elsif round(v_cur, 2) = (it ->> 'fee')::numeric then v_applied := 'same';
        elsif p_overwrite_fees then update booking.refunds set provider_fee = (it ->> 'fee')::numeric where id = (it ->> 'refund_id')::bigint; v_applied := 'overwritten';
        else v_applied := 'conflict';
        end if;
      end if;
      insert into booking.settlement_items(settlement_id, line_no, kind, reference, payment_id, refund_id, gross, fee, net, match_status, fee_applied, raw)
      values (v_sid, (it ->> 'line_no')::int, it ->> 'kind', it ->> 'reference', (it ->> 'payment_id')::bigint, (it ->> 'refund_id')::bigint,
              (it ->> 'gross')::numeric, (it ->> 'fee')::numeric, (it ->> 'net')::numeric, it ->> 'match_status', v_applied, it -> 'raw');
    end loop;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (auth.uid(), booking._jwt_role(), 'settlements', v_sid::text, 'SETTLEMENT_IMPORTED',
            jsonb_build_object('provider', p_provider, 'batch', b.j ->> 'batch', 'filename', left(p_filename, 200), 'md5', v_md5, 'actor', p_actor) || (b.j - 'batch'));
  end loop;
  return v_res || jsonb_build_object('imported', true,
    'fees_set', (select count(*) from booking.settlement_items i join booking.settlements s on s.id = i.settlement_id where s.source_md5 = v_md5 and s.provider = p_provider and i.fee_applied in ('set', 'overwritten')),
    'fee_conflicts_kept', (select count(*) from booking.settlement_items i join booking.settlements s on s.id = i.settlement_id where s.source_md5 = v_md5 and s.provider = p_provider and i.fee_applied = 'conflict'));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_import_settlement_csv(p_provider text, p_csv text, p_filename text DEFAULT NULL::text, p_dry_run boolean DEFAULT true, p_overwrite_fees boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('settings.edit');
  if not booking.has_permission('reports.view') then perform booking._err('forbidden', 'Ei oikeutta tähän toimintoon (reports.view)'); end if;
  return booking._settlement_import(p_provider, p_csv, p_filename, coalesce(p_dry_run, true), coalesce(p_overwrite_fees, false), coalesce(auth.uid()::text, 'admin'));
end $function$;

CREATE OR REPLACE FUNCTION booking.svc_import_settlement_csv(p_provider text, p_csv text, p_filename text DEFAULT NULL::text, p_dry_run boolean DEFAULT true, p_overwrite_fees boolean DEFAULT false, p_actor text DEFAULT 'Bottiavustus'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_actor is null or char_length(btrim(p_actor)) < 2 or char_length(p_actor) > 80 then perform booking._err('invalid_param', 'p_actor 2–80 merkkiä'); end if;
  return booking._settlement_import(p_provider, p_csv, p_filename, coalesce(p_dry_run, true), coalesce(p_overwrite_fees, false), btrim(p_actor));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_list_settlements(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('reports.view');
  if p_from is null or p_to is null or p_to < p_from or (p_to - p_from) > 366 then perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)'); end if;
  return jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to),
    'fee_account', nullif(btrim(coalesce((select c.settings #>> '{accounts,provider_fee}' from booking.integration_config c where c.key = 'procountor'), '')), ''),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'provider', s.provider, 'provider_label', booking._provider_admin_label(s.provider), 'batch_ref', s.batch_ref,
               'settled_on', s.settled_on, 'gross', s.gross, 'fee', s.fee, 'net', s.net, 'payments', s.payment_count, 'refunds', s.refund_count, 'other', s.other_count,
               'matched', s.matched_count, 'unmatched', s.unmatched_count, 'fee_account', s.fee_account, 'posted', s.posted,
               'filename', s.source_filename, 'imported_at', s.imported_at) order by s.settled_on, s.provider, s.batch_ref)
               from booking.settlements s where s.settled_on between p_from and p_to), '[]'::jsonb),
    'totals', (select jsonb_build_object('batches', count(*), 'gross', coalesce(sum(s.gross), 0), 'fee', coalesce(sum(s.fee), 0), 'net', coalesce(sum(s.net), 0), 'unmatched', coalesce(sum(s.unmatched_count), 0))
                 from booking.settlements s where s.settled_on between p_from and p_to));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_get_settlement(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s booking.settlements;
begin
  perform booking._require_permission('reports.view');
  select * into s from booking.settlements where id = p_id;
  if not found then perform booking._err('not_found', 'Tilitystä ei löydy'); end if;
  return to_jsonb(s) - 'imported_by' || jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object('line_no', i.line_no, 'kind', i.kind, 'reference', i.reference,
           'payment_id', i.payment_id, 'refund_id', i.refund_id, 'order_no', o.order_no, 'gross', i.gross, 'fee', i.fee, 'net', i.net, 'match_status', i.match_status, 'fee_applied', i.fee_applied) order by i.line_no)
           from booking.settlement_items i left join booking.payments p on p.id = coalesce(i.payment_id, (select f.payment_id from booking.refunds f where f.id = i.refund_id))
           left join booking.orders o on o.id = p.order_id where i.settlement_id = s.id), '[]'::jsonb));
end $function$;

revoke all on function booking._settlement_num(text) from public, anon, authenticated;
revoke all on function booking._settlement_parse_csv(text) from public, anon, authenticated;
revoke all on function booking._settlement_import(text, text, text, boolean, boolean, text) from public, anon, authenticated;
revoke all on function booking.admin_import_settlement_csv(text, text, text, boolean, boolean) from public, anon;
grant execute on function booking.admin_import_settlement_csv(text, text, text, boolean, boolean) to authenticated;
revoke all on function booking.svc_import_settlement_csv(text, text, text, boolean, boolean, text) from public, anon, authenticated;
grant execute on function booking.svc_import_settlement_csv(text, text, text, boolean, boolean, text) to service_role;
revoke all on function booking.admin_list_settlements(date, date) from public, anon;
grant execute on function booking.admin_list_settlements(date, date) to authenticated;
revoke all on function booking.admin_get_settlement(bigint) from public, anon;
grant execute on function booking.admin_get_settlement(bigint) to authenticated;

-- Kulutilin asetus omana kutsunaan: koskee vain avainta accounts.provider_fee (ei Procountorin tilaa, daily_enabled-asetusta eikä muita tilejä).
CREATE OR REPLACE FUNCTION booking.admin_set_provider_fee_account(p_account text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v text := btrim(coalesce(p_account, '')); v_old text;
begin
  perform booking._require_permission('settings.edit');
  if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
  select c.settings #>> '{accounts,provider_fee}' into v_old from booking.integration_config c where c.key = 'procountor' for update;
  if not found then perform booking._err('not_configured', 'procountor-asetus puuttuu'); end if;
  update booking.integration_config c
     set settings = case when v = '' then c.settings #- '{accounts,provider_fee}'
                         else c.settings || jsonb_build_object('accounts', coalesce(c.settings -> 'accounts', '{}'::jsonb) || jsonb_build_object('provider_fee', v)) end,
         updated_by = auth.uid()
   where c.key = 'procountor';
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'integration_config', 'procountor', 'PROVIDER_FEE_ACCOUNT_SET', jsonb_build_object('provider_fee', v_old), jsonb_build_object('provider_fee', nullif(v, '')));
  return jsonb_build_object('provider_fee', nullif(v, ''));
end $function$;
revoke all on function booking.admin_set_provider_fee_account(text) from public, anon;
grant execute on function booking.admin_set_provider_fee_account(text) to authenticated;

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
      'vat_rounding', coalesce(c.settings#>>'{accounts,vat_rounding}', ''),  -- booking_347 (K5)
      'provider_fee', coalesce(c.settings#>>'{accounts,provider_fee}', ''),  -- booking_349 (K9): maksunvälityskulut, ei vielä kirjata
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
  accounts jsonb; sales jsonb := '{}'::jsonb; clearing jsonb := '{}'::jsonb; rounding text; vat_rounding text; provider_fee text;
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
  -- booking_347 (K5): ALV-pyöristystili
  vat_rounding := btrim(coalesce(accounts->>'vat_rounding', ''));
  -- booking_349 (K9): maksunvälityskulujen tili
  -- puuttuva avain säilyttää nykyisen arvon (vanhempi lomake ei lähetä kenttää)
  if accounts ? 'provider_fee' then provider_fee := btrim(coalesce(accounts->>'provider_fee', ''));
  else provider_fee := btrim(coalesce(cur.settings#>>'{accounts,provider_fee}', '')); end if;
  if provider_fee <> '' and provider_fee !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
  if vat_rounding <> '' and vat_rounding !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
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
         'accounts', jsonb_build_object('rounding', nullif(rounding, ''), 'vat_rounding', nullif(vat_rounding, ''), 'provider_fee', nullif(provider_fee, ''), 'sales_by_vat', sales, 'clearing_by_method', clearing));
  s := jsonb_strip_nulls(s);
  update booking.integration_config
     set mode = v_mode, settings = s, updated_by = auth.uid()
   where key = 'procountor';
  return booking.admin_get_procountor_settings();
end $function$;
