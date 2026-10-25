-- booking_126_johku_sync (22.10.2026)
-- Johku-synkan kirjoituspolku. EI ajeta tuotantoon tästä haarasta: Bottiavustus ajaa migraation katselmoinnin jälkeen.
--
-- Palvelin (Varmistaja) ei saa service_role-avainta. Edge-funktio johku-sync tarkistaa otsakkeen
-- x-johku-sync-secret (salaisuus JOHKU_SYNC_SECRET) ja kutsuu näitä funktioita service_rolella.
-- Funktiot kirjoittavat vain external_source = 'johku' -rivejä ja noudattavat SYNC_SAANNOT.md:
--   * piilotettua varausta ei päivitetä, ei aktivoida eikä piilotusta pureta
--   * merged_into / merged_into_package ohitetaan
--   * addon-riviä ja toiseen tilaukseen siirrettyä riviä ei kirjoiteta takaisin
--   * addon_merge-tilauksen total_gross säilyy myös peruutuksessa (johku_removed)
--   * kb 44/45 (Johku-tuotteet 103, 126, 113, 125) ei saa omaa varausta
--   * paketin (Johku 179) 0 € optiontype 3 -oheisvuoro ei saa omaa varausta
--   * kadonnut rivi peruutetaan (cancel_reason johku_removed), ei poisteta
--   * ei maksuja, kuitteja, sähköpostijonoa, hyvityksiä eikä Procountor-rivejä
--   * asiakkaan jo täytettyä kenttää ei ylikirjoiteta, jos se poikkeaa edellisestä viennistä
--     (hallinta on voinut muokata sitä tuonnin jälkeen)
-- Rivikohtainen audit ohitetaan (henkilötietojen kopio). Jokainen apply kirjoittaa yhden
-- audit_log-rivin, jonka row_pk on johku_sync_runs.id (payload.run_id), ilman henkilötietoja.
-- Piilotusten, merged-avainten ja addon-rivien määrä ei saa laskea. Jos laskee, koko kutsu perutaan.

set local lock_timeout = '5s';

create table booking.johku_sync_runs (
  id            bigint generated always as identity primary key,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  status        text not null check (status in ('running', 'ok', 'failed', 'dry_run')),
  mode          text not null default 'incremental' check (mode in ('incremental', 'full', 'cards', 'dry_run')),
  counts        jsonb not null default '{}'::jsonb,
  error_summary text,
  constraint johku_sync_runs_error_len check (error_summary is null or char_length(error_summary) <= 500)
);
comment on table booking.johku_sync_runs is
  'Johku-synkan ajoloki. Ei henkilötietoja: vain ajat, tila, lukumäärät ja lyhyt virhekoodi.';
create index johku_sync_runs_started_idx on booking.johku_sync_runs (started_at desc);

alter table booking.johku_sync_runs enable row level security;
revoke all on booking.johku_sync_runs from public, anon, authenticated;
grant select, insert, update on booking.johku_sync_runs to service_role;
grant usage, select on sequence booking.johku_sync_runs_id_seq to service_role;

-- ---------- tila synkalle (ei nimiä, sähköposteja, puhelimia eikä korttikoodeja) ----------
create or replace function booking.svc_johku_sync_state()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_seq bigint;
begin
  select s.last_value into v_seq
    from pg_sequences s
   where s.schemaname = 'booking' and s.sequencename = 'orders_order_no_seq';
  return jsonb_build_object(
    'hidden_reservations', coalesce((
      select jsonb_agg(r.external_id order by r.external_id)
        from booking.reservations r
       where r.external_source = 'johku' and r.hidden_at is not null), '[]'::jsonb),
    'merged_reservations', coalesce((
      select jsonb_agg(r.external_id order by r.external_id)
        from booking.reservations r
       where r.external_source = 'johku' and r.external_meta ? 'merged_into'), '[]'::jsonb),
    'package_merged_reservations', coalesce((
      select jsonb_agg(r.external_id order by r.external_id)
        from booking.reservations r
       where r.external_source = 'johku' and (r.external_meta -> 'model') ? 'merged_into_package'), '[]'::jsonb),
    'frozen_orders', coalesce((
      select jsonb_agg(o.external_id order by o.external_id)
        from booking.orders o
       where o.external_source = 'johku' and o.external_meta ? 'addon_merge'), '[]'::jsonb),
    'order_status', coalesce((
      select jsonb_object_agg(o.external_id, o.status)
        from booking.orders o
       where o.external_source = 'johku' and o.external_id is not null), '{}'::jsonb),
    'addon_items', coalesce((
      select jsonb_agg(i.external_id order by i.external_id)
        from booking.order_items i
       where i.external_source = 'johku' and i.kind = 'addon'), '[]'::jsonb),
    'moved_items', coalesce((
      select jsonb_agg(i.external_id order by i.external_id)
        from booking.order_items i
       where i.external_source = 'johku'
         and nullif(i.price_breakdown #>> '{merged_from,order_id}', '') is not null
         and nullif(i.price_breakdown #>> '{merged_from,order_id}', '') is distinct from i.order_id::text), '[]'::jsonb),
    'anonymized_customers', coalesce((
      select jsonb_agg(c.external_id order by c.external_id)
        from booking.customers c
       where c.external_source = 'johku' and c.anonymized_at is not null), '[]'::jsonb),
    'taken_order_nos', coalesce((select jsonb_agg(o.order_no order by o.order_no) from booking.orders o), '[]'::jsonb),
    'sequence_last', v_seq,
    'hidden_count', (select count(*) from booking.reservations r where r.hidden_at is not null)
  );
end $$;

-- ---------- ajoloki ----------
create or replace function booking.svc_johku_sync_log(p_row jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id bigint;
  v_status text := p_row ->> 'status';
  v_mode text := coalesce(p_row ->> 'mode', 'incremental');
  v_err text;
begin
  if v_status is null or v_status not in ('running', 'ok', 'failed', 'dry_run') then
    perform booking._err('invalid_param', 'status');
  end if;
  if v_mode not in ('incremental', 'full', 'cards', 'dry_run') then
    perform booking._err('invalid_param', 'mode');
  end if;
  v_err := nullif(left(regexp_replace(coalesce(p_row ->> 'error', ''),
            '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '[email]', 'g'), 500), '');
  update booking.johku_sync_runs
     set status = 'failed', finished_at = now(), error_summary = 'stale'
   where status = 'running' and started_at < now() - interval '6 hours';
  if p_row ? 'id' and nullif(p_row ->> 'id', '') is not null then
    v_id := (p_row ->> 'id')::bigint;
    update booking.johku_sync_runs
       set status = v_status,
           finished_at = case when v_status = 'running' then null else now() end,
           mode = v_mode,
           counts = coalesce(p_row -> 'counts', '{}'::jsonb),
           error_summary = v_err
     where id = v_id;
    if not found then perform booking._err('not_found', 'run'); end if;
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;
  insert into booking.johku_sync_runs(status, mode, counts, error_summary, finished_at)
  values (v_status, v_mode, coalesce(p_row -> 'counts', '{}'::jsonb), v_err,
          case when v_status = 'running' then null else now() end)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Tyhjä kenttä täytetään. Ilman edellistä vientiä täyttä kenttää ei muuteta.
-- Jos tietokannan arvo on yhä sama kuin edellinen vienti, Johkun uusi arvo kirjoitetaan.
create or replace function booking._johku_sync_text(p_current text, p_incoming text, p_prev text, p_has_prev boolean)
returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when nullif(btrim(coalesce(p_current, '')), '') is null then p_incoming
    when not coalesce(p_has_prev, false) then p_current
    when btrim(p_current) is not distinct from btrim(coalesce(p_prev, '')) then p_incoming
    else p_current
  end;
$$;

create or replace function booking._johku_sync_bool(p_current boolean, p_incoming boolean, p_prev boolean, p_has_prev boolean)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select case
    when not coalesce(p_has_prev, false) then p_current
    when p_current is not distinct from p_prev then p_incoming
    else p_current
  end;
$$;

revoke all on function booking._johku_sync_text(text, text, text, boolean) from public, anon, authenticated;
revoke all on function booking._johku_sync_bool(boolean, boolean, boolean, boolean) from public, anon, authenticated;

-- ---------- kirjoitus ----------
create or replace function booking.svc_johku_sync_apply(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  r jsonb;
  v_ext text;
  v_state text;
  v_detail text;
  v_code text;
  v_cust booking.customers;
  v_order booking.orders;
  v_item booking.order_items;
  v_item_exists boolean;
  v_res booking.reservations;
  v_parent booking.order_items;
  v_name text;
  v_email text;
  v_phone text;
  v_country text;
  v_consent boolean;
  v_consent_new boolean;
  v_consent_prev boolean;
  v_has_prev boolean;
  v_prev jsonb;
  v_at timestamptz;
  v_run text;
  v_bid text;
  v_kind text;
  v_locale text;
  v_total numeric;
  v_pay text;
  v_status text;
  v_no bigint;
  v_seq text;
  v_seq_last bigint;
  v_clash boolean;
  v_freeze boolean;
  v_addon bigint;
  v_kb bigint;
  v_space bigint;
  v_mode text;
  v_off integer;
  v_mins integer;
  v_pools bigint[];
  v_res_id bigint;
  v_start timestamptz;
  v_end timestamptz;
  v_persons integer;
  v_legs jsonb;
  v_applied jsonb := '{"customers":[],"orders":[],"items":[],"reservations":[],"cancel_orders":[],"cancel_reservations":[]}'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_review jsonb := '[]'::jsonb;
  v_seen jsonb := '{}'::jsonb;
  v_pay_n bigint; v_rec_n bigint; v_mail_n bigint; v_acct_n bigint; v_ref_n bigint; v_gc_n bigint; v_gcl_n bigint;
  v_hidden bigint; v_merged bigint; v_frozen bigint; v_addon_n bigint;
  v_hidden2 bigint; v_merged2 bigint; v_frozen2 bigint; v_addon2 bigint;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    perform booking._err('invalid_param', 'payload');
  end if;
  if p_payload ?| array['payments','receipts','email_outbox','accounting_outbox','refunds','payment_lines','hidden_at'] then
    perform booking._err('forbidden_key', 'payload');
  end if;
  v_run := nullif(p_payload ->> 'run_id', '');
  if v_run is not null and v_run !~ '^[0-9]{1,12}$' then
    perform booking._err('invalid_param', 'run_id');
  end if;
  if jsonb_array_length(coalesce(p_payload -> 'customers', '[]'::jsonb)) > 400
     or jsonb_array_length(coalesce(p_payload -> 'orders', '[]'::jsonb)) > 200
     or jsonb_array_length(coalesce(p_payload -> 'items', '[]'::jsonb)) > 800
     or jsonb_array_length(coalesce(p_payload -> 'reservations', '[]'::jsonb)) > 400
     or jsonb_array_length(coalesce(p_payload -> 'cancel_orders', '[]'::jsonb)) > 400
     or jsonb_array_length(coalesce(p_payload -> 'cancel_reservations', '[]'::jsonb)) > 400 then
    perform booking._err('too_large', 'chunk');
  end if;

  perform set_config('booking.skip_audit', 'on', true);
  perform pg_advisory_xact_lock(hashtextextended('booking:johku-sync', 0));

  select count(*) into v_pay_n from booking.payments;
  select count(*) into v_rec_n from booking.receipts;
  select count(*) into v_mail_n from booking.email_outbox;
  select count(*) into v_acct_n from booking.accounting_outbox;
  select count(*) into v_ref_n from booking.refunds;
  select count(*) into v_gc_n from booking.gift_cards;
  select count(*) into v_gcl_n from booking.gift_card_ledger;
  select count(*) into v_hidden from booking.reservations where hidden_at is not null;
  select count(*) into v_merged from booking.reservations
   where external_meta ? 'merged_into' or (external_meta -> 'model') ? 'merged_into_package';
  select count(*) into v_frozen from booking.orders where external_meta ? 'addon_merge';
  select count(*) into v_addon_n from booking.order_items where kind = 'addon';

  -- asiakkaat
  for r in select value from jsonb_array_elements(coalesce(p_payload -> 'customers', '[]'::jsonb)) loop
    begin
      v_ext := r ->> 'external_id';
      if v_ext is null or v_ext !~ '^[0-9]{1,12}$' or v_seen ? ('c:' || v_ext) then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'customer', 'external_id', coalesce(v_ext, '?'), 'code', 'bad_id'));
        continue;
      end if;
      v_seen := v_seen || jsonb_build_object('c:' || v_ext, true);
      v_name := left(btrim(coalesce(r ->> 'name', '')), 200);
      if char_length(v_name) < 1 then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'customer', 'external_id', v_ext, 'code', 'bad_name'));
        continue;
      end if;
      v_email := nullif(lower(btrim(coalesce(r ->> 'email', ''))), '');
      if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
      v_consent := coalesce((r ->> 'marketing_consent')::boolean, false);
      v_at := nullif(r ->> 'marketing_consent_at', '')::timestamptz;
      if v_consent and v_at is null then v_at := now(); end if;
      v_bid := nullif(btrim(coalesce(r ->> 'business_id', '')), '');
      if v_bid is not null and not booking._business_id_ok(v_bid) then v_bid := null; end if;
      v_kind := case when r ->> 'customer_kind' = 'company' then 'company' else 'private' end;
      v_locale := case when r ->> 'language' in ('fi', 'en', 'sv') then r ->> 'language' else 'fi' end;
      v_phone := nullif(left(btrim(coalesce(r ->> 'phone', '')), 50), '');
      v_country := coalesce(nullif(left(btrim(coalesce(r ->> 'country', '')), 80), ''), 'FI');
      select * into v_cust from booking.customers where external_source = 'johku' and external_id = v_ext;
      if found and v_cust.anonymized_at is not null then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'customer', 'external_id', v_ext, 'code', 'anonymized'));
        continue;
      end if;
      if found then
        v_has_prev := jsonb_typeof(r -> 'prev') = 'object';
        v_prev := case when v_has_prev then r -> 'prev' else '{}'::jsonb end;
        v_consent_prev := case
          when v_has_prev and (v_prev ? 'marketing_consent') then (v_prev ->> 'marketing_consent')::boolean
          else null
        end;
        v_consent_new := booking._johku_sync_bool(v_cust.marketing_consent, v_consent, v_consent_prev, v_consent_prev is not null);
        update booking.customers set
          name = booking._johku_sync_text(name, v_name, v_prev ->> 'name', v_has_prev),
          email = case
            when nullif(btrim(coalesce(email, '')), '') is null then v_email
            when not v_has_prev then email
            when lower(btrim(email)) is not distinct from lower(btrim(coalesce(v_prev ->> 'email', ''))) then v_email
            else email
          end,
          phone = booking._johku_sync_text(phone, v_phone, v_prev ->> 'phone', v_has_prev),
          company = booking._johku_sync_text(company, nullif(btrim(coalesce(r ->> 'company', '')), ''), v_prev ->> 'company', v_has_prev),
          address = booking._johku_sync_text(address, nullif(r ->> 'address', ''), v_prev ->> 'address', v_has_prev),
          zip = booking._johku_sync_text(zip, nullif(r ->> 'zip', ''), v_prev ->> 'zip', v_has_prev),
          city = booking._johku_sync_text(city, nullif(r ->> 'city', ''), v_prev ->> 'city', v_has_prev),
          country = booking._johku_sync_text(country, v_country, v_prev ->> 'country', v_has_prev),
          language = booking._johku_sync_text(language, v_locale, v_prev ->> 'language', v_has_prev),
          customer_kind = booking._johku_sync_text(customer_kind, v_kind, v_prev ->> 'customer_kind', v_has_prev),
          business_id = booking._johku_sync_text(business_id, v_bid, v_prev ->> 'business_id', v_has_prev),
          einvoice_address = booking._johku_sync_text(einvoice_address, nullif(r ->> 'einvoice_address', ''), v_prev ->> 'einvoice_address', v_has_prev),
          einvoice_operator = booking._johku_sync_text(einvoice_operator, nullif(r ->> 'einvoice_operator', ''), v_prev ->> 'einvoice_operator', v_has_prev),
          marketing_consent = v_consent_new,
          marketing_consent_at = case
            when v_consent_new is not distinct from v_cust.marketing_consent then marketing_consent_at
            when v_consent_new then coalesce(marketing_consent_at, v_at)
            else marketing_consent_at
          end,
          marketing_consent_source = case
            when v_consent_new and not v_cust.marketing_consent then 'johku_import'
            else marketing_consent_source
          end
        where id = v_cust.id and external_source = 'johku';
      else
        insert into booking.customers(
          external_source, external_id, name, email, phone, company, address, zip, city, country, language,
          customer_kind, business_id, einvoice_address, einvoice_operator,
          marketing_consent, marketing_consent_at, marketing_consent_source, created_at)
        values (
          'johku', v_ext, v_name, v_email, nullif(left(btrim(coalesce(r ->> 'phone', '')), 50), ''),
          nullif(btrim(coalesce(r ->> 'company', '')), ''), nullif(r ->> 'address', ''), nullif(r ->> 'zip', ''),
          nullif(r ->> 'city', ''), v_country, v_locale,
          v_kind, v_bid, nullif(r ->> 'einvoice_address', ''), nullif(r ->> 'einvoice_operator', ''),
          v_consent, case when v_consent then v_at else null end, case when v_consent then 'johku_import' else null end,
          coalesce(nullif(r ->> 'created_at', '')::timestamptz, now()));
      end if;
      v_applied := jsonb_set(v_applied, '{customers}', (v_applied -> 'customers') || to_jsonb(v_ext));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      v_code := case when v_state = 'BK001' then coalesce(nullif(v_detail, ''), 'row_rejected') else 'row_rejected' end;
      v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'customer', 'external_id', coalesce(v_ext, '?'), 'code', v_code));
    end;
  end loop;

  -- tilaukset
  for r in select value from jsonb_array_elements(coalesce(p_payload -> 'orders', '[]'::jsonb)) loop
    begin
      v_ext := r ->> 'external_id';
      if v_ext is null or v_ext !~ '^[0-9]{1,12}$' or v_seen ? ('o:' || v_ext) then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'order', 'external_id', coalesce(v_ext, '?'), 'code', 'bad_id'));
        continue;
      end if;
      v_seen := v_seen || jsonb_build_object('o:' || v_ext, true);
      v_status := r ->> 'status';
      v_pay := r ->> 'payment_status';
      if v_status not in ('pending', 'confirmed', 'cancelled', 'expired', 'completed')
         or v_pay not in ('unpaid', 'pending', 'paid', 'partially_paid', 'refunded', 'partially_refunded', 'failed') then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'order', 'external_id', v_ext, 'code', 'bad_status'));
        continue;
      end if;
      v_total := (r ->> 'total_gross')::numeric;
      if v_total is null or v_total < 0 then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'order', 'external_id', v_ext, 'code', 'bad_total'));
        continue;
      end if;
      v_locale := case when r ->> 'locale' in ('fi', 'en', 'sv') then r ->> 'locale' else 'fi' end;
      v_kind := case when r ->> 'customer_kind' = 'company' then 'company' else 'private' end;
      v_no := coalesce((r ->> 'johku_order_no')::bigint, v_ext::bigint);
      select * into v_order from booking.orders where external_source = 'johku' and external_id = v_ext;
      v_freeze := found and coalesce(v_order.external_meta, '{}'::jsonb) ? 'addon_merge';
      if v_freeze then v_total := v_order.total_gross; end if;
      if found and v_order.status = 'expired' and v_status = 'pending' then v_status := 'expired'; end if;
      if found and v_order.status = 'completed' and v_status = 'pending' then v_status := 'completed'; end if;
      if not found then
        v_clash := exists (select 1 from booking.orders o where o.order_no = v_no);
        if v_clash then
          insert into booking.orders(
            customer_id, status, payment_status, total_gross, currency, source_channel, locale,
            customer_note, internal_note, confirmed_at, cancelled_at, external_source, external_id, johku_order_no,
            created_at, customer_kind, billing, invoice_reference, external_meta)
          values (
            (select c.id from booking.customers c where c.external_source = 'johku' and c.external_id = nullif(r ->> 'customer_ext', '')),
            v_status, v_pay, v_total, 'EUR', 'johku_import', v_locale,
            nullif(left(coalesce(r ->> 'customer_note', ''), 2000), ''),
            nullif(left(coalesce(r ->> 'internal_note', ''), 500), ''),
            nullif(r ->> 'confirmed_at', '')::timestamptz, nullif(r ->> 'cancelled_at', '')::timestamptz,
            'johku', v_ext, v_no, coalesce(nullif(r ->> 'created_at', '')::timestamptz, now()),
            v_kind, r -> 'billing', nullif(left(coalesce(r ->> 'invoice_reference', ''), 100), ''),
            jsonb_build_object('johku', coalesce(r -> 'johku_meta', '{}'::jsonb), 'content_hash', r ->> 'sync_hash', 'source', 'johku', 'order_no_clash', true));
        else
          insert into booking.orders(
            order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale,
            customer_note, internal_note, confirmed_at, cancelled_at, external_source, external_id, johku_order_no,
            created_at, customer_kind, billing, invoice_reference, external_meta)
          values (
            v_no,
            (select c.id from booking.customers c where c.external_source = 'johku' and c.external_id = nullif(r ->> 'customer_ext', '')),
            v_status, v_pay, v_total, 'EUR', 'johku_import', v_locale,
            nullif(left(coalesce(r ->> 'customer_note', ''), 2000), ''),
            nullif(left(coalesce(r ->> 'internal_note', ''), 500), ''),
            nullif(r ->> 'confirmed_at', '')::timestamptz, nullif(r ->> 'cancelled_at', '')::timestamptz,
            'johku', v_ext, v_no, coalesce(nullif(r ->> 'created_at', '')::timestamptz, now()),
            v_kind, r -> 'billing', nullif(left(coalesce(r ->> 'invoice_reference', ''), 100), ''),
            jsonb_build_object('johku', coalesce(r -> 'johku_meta', '{}'::jsonb), 'content_hash', r ->> 'sync_hash', 'source', 'johku'));
          v_seq := pg_get_serial_sequence('booking.orders', 'order_no');
          if v_seq is not null then
            select s.last_value into v_seq_last from pg_sequences s
             where s.schemaname = split_part(v_seq, '.', 1) and s.sequencename = split_part(v_seq, '.', 2);
            if v_seq_last is null or v_no > v_seq_last then
              perform setval(v_seq, v_no, true);
            end if;
          end if;
        end if;
      else
        update booking.orders set
          customer_id = coalesce((select c.id from booking.customers c where c.external_source = 'johku' and c.external_id = nullif(r ->> 'customer_ext', '')), customer_id),
          status = v_status,
          payment_status = v_pay,
          total_gross = v_total,
          locale = v_locale,
          customer_note = nullif(left(coalesce(r ->> 'customer_note', ''), 2000), ''),
          internal_note = nullif(left(coalesce(r ->> 'internal_note', ''), 500), ''),
          confirmed_at = coalesce(confirmed_at, nullif(r ->> 'confirmed_at', '')::timestamptz),
          cancelled_at = case when v_status = 'cancelled' then coalesce(cancelled_at, nullif(r ->> 'cancelled_at', '')::timestamptz, now()) else cancelled_at end,
          customer_kind = v_kind,
          billing = r -> 'billing',
          invoice_reference = nullif(left(coalesce(r ->> 'invoice_reference', ''), 100), ''),
          external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('johku', coalesce(r -> 'johku_meta', '{}'::jsonb), 'content_hash', r ->> 'sync_hash', 'source', 'johku')
        where id = v_order.id and external_source = 'johku';
        if v_freeze and (select o.total_gross from booking.orders o where o.id = v_order.id) is distinct from v_order.total_gross then
          perform booking._err('johku_sync_side_effect', 'addon_merge_total');
        end if;
      end if;
      v_applied := jsonb_set(v_applied, '{orders}', (v_applied -> 'orders') || to_jsonb(v_ext));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      v_code := case when v_state = 'BK001' then coalesce(nullif(v_detail, ''), 'row_rejected') else 'row_rejected' end;
      v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'order', 'external_id', coalesce(v_ext, '?'), 'code', v_code));
    end;
  end loop;

  -- rivit
  for r in select value from jsonb_array_elements(coalesce(p_payload -> 'items', '[]'::jsonb)) loop
    begin
      v_ext := r ->> 'external_id';
      if v_ext is null or v_ext !~ '^[0-9]{1,12}$' or v_seen ? ('i:' || v_ext) then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', coalesce(v_ext, '?'), 'code', 'bad_id'));
        continue;
      end if;
      v_seen := v_seen || jsonb_build_object('i:' || v_ext, true);
      v_kind := r ->> 'kind';
      if v_kind not in ('reservation', 'product', 'gift_card', 'fee', 'discount', 'addon') then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', v_ext, 'code', 'bad_kind'));
        continue;
      end if;
      if r ->> 'johku_product_id' = any (array['103', '126', '113', '125']) then
        v_kind := 'addon';
      end if;
      v_item_exists := false;
      select * into v_item from booking.order_items where external_source = 'johku' and external_id = v_ext;
      v_item_exists := found;
      if v_item_exists and v_item.kind = 'addon' then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', v_ext, 'code', 'addon_row'));
        continue;
      end if;
      if v_item_exists and nullif(v_item.price_breakdown #>> '{merged_from,order_id}', '') is not null
         and nullif(v_item.price_breakdown #>> '{merged_from,order_id}', '') is distinct from v_item.order_id::text then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', v_ext, 'code', 'moved_item'));
        continue;
      end if;
      if v_item_exists and exists (
           select 1 from booking.orders o
            where o.id = v_item.order_id and o.external_source = 'johku'
              and o.external_id is distinct from r ->> 'order_ext') then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', v_ext, 'code', 'moved_item'));
        continue;
      end if;
      v_kb := nullif(r ->> 'kb_product_id', '')::bigint;
      if v_kb is not null and not exists (select 1 from kb.products p where p.id = v_kb) then v_kb := null; end if;
      v_addon := null;
      if v_kind = 'addon' then
        select a.id into v_addon from booking.addons a where a.code = r ->> 'addon_code';
        if v_addon is null then
          v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', v_ext, 'code', 'unknown_addon'));
          continue;
        end if;
      end if;
      if not exists (select 1 from booking.orders o where o.external_source = 'johku' and o.external_id = r ->> 'order_ext') then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', v_ext, 'code', 'missing_order'));
        continue;
      end if;
      if v_item_exists then
        update booking.order_items set
          product_id = coalesce(v_kb, product_id),
          product_name = left(coalesce(r ->> 'product_name', product_name), 200),
          quantity = greatest(coalesce((r ->> 'quantity')::int, quantity), 0),
          unit_price_gross = (r ->> 'unit_price_gross')::numeric,
          line_total_gross = (r ->> 'line_total_gross')::numeric,
          vat_rate = (r ->> 'vat_rate')::numeric,
          price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || coalesce(r -> 'price_breakdown', '{}'::jsonb),
          external_product_id = coalesce(r ->> 'johku_product_id', external_product_id)
        where id = v_item.id and external_source = 'johku' and kind is distinct from 'addon';
      else
        insert into booking.order_items(
          order_id, product_id, product_name, kind, addon_id, quantity, unit_price_gross, discount_amount,
          line_total_gross, vat_rate, price_breakdown, external_source, external_id, external_product_id, created_at)
        values (
          (select o.id from booking.orders o where o.external_source = 'johku' and o.external_id = r ->> 'order_ext'),
          v_kb, left(coalesce(r ->> 'product_name', '(nimetön rivi)'), 200), v_kind, v_addon,
          greatest(coalesce((r ->> 'quantity')::int, 1), 0),
          (r ->> 'unit_price_gross')::numeric, 0, (r ->> 'line_total_gross')::numeric, coalesce((r ->> 'vat_rate')::numeric, 25.5),
          coalesce(r -> 'price_breakdown', '{}'::jsonb), 'johku', v_ext, r ->> 'johku_product_id',
          coalesce(nullif(r ->> 'created_at', '')::timestamptz, now()));
      end if;
      v_applied := jsonb_set(v_applied, '{items}', (v_applied -> 'items') || to_jsonb(v_ext));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      v_code := case when v_state = 'BK001' then coalesce(nullif(v_detail, ''), 'row_rejected') else 'row_rejected' end;
      v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'item', 'external_id', coalesce(v_ext, '?'), 'code', v_code));
    end;
  end loop;

  -- vanhempi (lisäpalvelu / oheisrivi). Ei siirretä riviä, jolla parent on jo asetettu toiseen tilaukseen.
  for r in select value from jsonb_array_elements(coalesce(p_payload -> 'items', '[]'::jsonb)) loop
    v_ext := r ->> 'external_id';
    if nullif(r ->> 'parent_ext', '') is null then continue; end if;
    select * into v_item from booking.order_items where external_source = 'johku' and external_id = v_ext;
    if not found or v_item.kind = 'addon' and v_item.parent_item_id is not null then continue; end if;
    if v_item.kind = 'addon' and exists (select 1 from booking.order_items x where x.id = v_item.id and x.kind = 'addon' and x.parent_item_id is not null) then
      continue;
    end if;
    select * into v_parent from booking.order_items where external_source = 'johku' and external_id = r ->> 'parent_ext';
    if not found or v_parent.order_id is distinct from v_item.order_id then continue; end if;
    if v_item.parent_item_id is null then
      update booking.order_items set parent_item_id = v_parent.id
       where id = v_item.id and external_source = 'johku' and parent_item_id is null;
    end if;
  end loop;

  -- varaukset
  for r in select value from jsonb_array_elements(coalesce(p_payload -> 'reservations', '[]'::jsonb)) loop
    begin
      v_ext := r ->> 'external_id';
      if v_ext is null or v_ext !~ '^[0-9]{1,12}$' or v_seen ? ('r:' || v_ext) then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', coalesce(v_ext, '?'), 'code', 'bad_id'));
        continue;
      end if;
      v_seen := v_seen || jsonb_build_object('r:' || v_ext, true);
      v_res_id := null;
      select id into v_res_id from booking.reservations where external_source = 'johku' and external_id = v_ext;
      if found then
        select * into v_res from booking.reservations where id = v_res_id;
      end if;
      if v_res_id is not null then
        if v_res.hidden_at is not null
           or coalesce(v_res.external_meta, '{}'::jsonb) ? 'merged_into'
           or (coalesce(v_res.external_meta, '{}'::jsonb) -> 'model') ? 'merged_into_package' then
          v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'hidden_or_merged'));
          continue;
        end if;
      end if;
      if r ->> 'johku_product_id' = any (array['103', '126', '113', '125']) then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'addon_product'));
        continue;
      end if;
      if coalesce(r ->> 'optiontype', '') = '3'
         and coalesce((r ->> 'line_price')::numeric, 0) = 0
         and r ->> 'parent_johku_product_id' = any (array['179'])
         and coalesce((r ->> 'parent_same_order')::boolean, false) then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'side_shift'));
        continue;
      end if;
      select * into v_item from booking.order_items where external_source = 'johku' and external_id = r ->> 'item_ext';
      if found and (v_item.kind = 'addon' or coalesce(v_item.price_breakdown ->> 'johku_role', '') in ('addon', 'side_shift')) then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'item_not_a_booking'));
        continue;
      end if;
      if not found or not exists (select 1 from booking.orders o where o.external_source = 'johku' and o.external_id = r ->> 'order_ext' and o.id = v_item.order_id) then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'missing_order_item'));
        continue;
      end if;
      v_status := r ->> 'status';
      if v_status not in ('confirmed', 'cancelled', 'completed', 'expired', 'no_show') then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'bad_status'));
        continue;
      end if;
      v_start := (r ->> 'starts_at')::timestamptz;
      v_end := (r ->> 'ends_at')::timestamptz;
      if v_start is null or v_end is null or v_end <= v_start then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'bad_time'));
        continue;
      end if;
      v_persons := greatest(coalesce((r ->> 'persons')::int, 1), 1);
      v_kb := nullif(r ->> 'kb_product_id', '')::bigint;
      if v_kb is not null and not exists (select 1 from kb.products p where p.id = v_kb) then v_kb := null; end if;
      v_space := null; v_mode := null; v_off := 0; v_mins := null;
      select psr.space_id, psr.mode, psr.offset_min, psr.minutes
        into v_space, v_mode, v_off, v_mins
        from booking.product_space_rules psr
       where v_kb is not null and psr.product_id = v_kb and psr.leg_no = 1 and psr.role = 'space' and psr.active and psr.selection = 'auto'
       order by psr.priority
       limit 1;
      if not found then
        v_space := null; v_mode := 'shared'; v_off := 0; v_mins := null;
        select id into v_space from booking.resources where code = 'ei_resurssia';
        if not found then v_space := null; end if;
      end if;
      if v_space is null then
        v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'no_space'));
        continue;
      end if;
      if v_mode is distinct from 'shared' then v_off := 0; v_mins := null; end if;
      select coalesce(array_agg(rs.id order by rs.id), '{}'::bigint[]) into v_pools
        from jsonb_array_elements_text(coalesce(r -> 'pool_codes', '[]'::jsonb)) c(code)
        join booking.resources rs on rs.code = c.code and rs.kind = 'capacity_pool';
      if v_res_id is null then
        insert into booking.reservations(
          order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, participant_breakdown,
          pool_ids, status, cancelled_at, cancel_reason, notes, checkin_at, checkout_at,
          external_source, external_id, created_at, external_meta, claim_offset_min, claim_minutes)
        values (
          v_item.order_id, v_item.id, v_kb, v_space, v_mode, v_start, v_end, v_persons, r -> 'participant_breakdown',
          coalesce(v_pools, '{}'::bigint[]), v_status,
          case when v_status = 'cancelled' then coalesce(nullif(r ->> 'cancelled_at', '')::timestamptz, now()) else null end,
          case when v_status = 'cancelled' then coalesce(nullif(r ->> 'cancel_reason', ''), 'johku_import') else null end,
          nullif(left(coalesce(r ->> 'notes', ''), 2000), ''),
          nullif(r ->> 'checkin_at', '')::timestamptz, nullif(r ->> 'checkout_at', '')::timestamptz,
          'johku', v_ext, coalesce(nullif(r ->> 'created_at', '')::timestamptz, now()),
          jsonb_build_object('source', 'johku', 'content_hash', r ->> 'sync_hash', 'johku_product_id', r ->> 'johku_product_id'),
          coalesce(v_off, 0), v_mins)
        returning * into v_res;
      else
        update booking.reservations set
          order_id = v_item.order_id,
          order_item_id = v_item.id,
          product_id = coalesce(v_kb, product_id),
          space_id = v_space,
          mode = v_mode,
          starts_at = v_start,
          ends_at = v_end,
          persons = v_persons,
          participant_breakdown = r -> 'participant_breakdown',
          pool_ids = coalesce(v_pools, '{}'::bigint[]),
          status = v_status,
          cancelled_at = case when v_status = 'cancelled' then coalesce(cancelled_at, now()) else cancelled_at end,
          cancel_reason = case when v_status = 'cancelled' then coalesce(nullif(r ->> 'cancel_reason', ''), cancel_reason, 'johku_import') else cancel_reason end,
          notes = nullif(left(coalesce(r ->> 'notes', ''), 2000), ''),
          checkin_at = coalesce(checkin_at, nullif(r ->> 'checkin_at', '')::timestamptz),
          checkout_at = coalesce(checkout_at, nullif(r ->> 'checkout_at', '')::timestamptz),
          claim_offset_min = coalesce(v_off, 0),
          claim_minutes = v_mins,
          external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('source', 'johku', 'content_hash', r ->> 'sync_hash', 'johku_product_id', r ->> 'johku_product_id')
        where id = v_res.id and external_source = 'johku' and hidden_at is null
        returning * into v_res;
      end if;
      if v_status = 'confirmed' then
        v_legs := booking.import_attach_legs(v_res.id);
        if coalesce((v_legs ->> 'ok')::boolean, false) is not true and coalesce(v_legs ->> 'note', '') is distinct from 'nothing_to_do' then
          v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', coalesce(v_legs ->> 'code', 'legs_failed')));
          continue;
        end if;
      end if;
      v_applied := jsonb_set(v_applied, '{reservations}', (v_applied -> 'reservations') || to_jsonb(v_ext));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      v_code := case when v_state = 'BK001' then coalesce(nullif(v_detail, ''), 'row_rejected') else 'row_rejected' end;
      v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', coalesce(v_ext, '?'), 'code', v_code));
    end;
  end loop;

  -- peruutukset (ei poistoa, ei piilotuksen purkua)
  for r in select value from jsonb_array_elements(coalesce(p_payload -> 'cancel_reservations', '[]'::jsonb)) loop
    begin
      v_ext := r #>> '{}';
      if v_ext is null or v_ext !~ '^[0-9]{1,12}$' then continue; end if;
      select * into v_res from booking.reservations where external_source = 'johku' and external_id = v_ext;
      if not found then
        v_applied := jsonb_set(v_applied, '{cancel_reservations}', (v_applied -> 'cancel_reservations') || to_jsonb(v_ext));
        continue;
      end if;
      if v_res.hidden_at is not null
         or coalesce(v_res.external_meta, '{}'::jsonb) ? 'merged_into'
         or (coalesce(v_res.external_meta, '{}'::jsonb) -> 'model') ? 'merged_into_package' then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', v_ext, 'code', 'hidden_or_merged'));
        v_applied := jsonb_set(v_applied, '{cancel_reservations}', (v_applied -> 'cancel_reservations') || to_jsonb(v_ext));
        continue;
      end if;
      update booking.reservations
         set status = 'cancelled',
             cancelled_at = coalesce(cancelled_at, now()),
             cancel_reason = 'johku_removed',
             external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('johku_removed', true)
       where id = v_res.id and external_source = 'johku' and hidden_at is null;
      v_applied := jsonb_set(v_applied, '{cancel_reservations}', (v_applied -> 'cancel_reservations') || to_jsonb(v_ext));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      v_code := case when v_state = 'BK001' then coalesce(nullif(v_detail, ''), 'row_rejected') else 'row_rejected' end;
      v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'reservation', 'external_id', coalesce(v_ext, '?'), 'code', v_code));
    end;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload -> 'cancel_orders', '[]'::jsonb)) loop
    begin
      v_ext := r #>> '{}';
      if v_ext is null or v_ext !~ '^[0-9]{1,12}$' then continue; end if;
      select * into v_order from booking.orders where external_source = 'johku' and external_id = v_ext;
      if not found then
        v_applied := jsonb_set(v_applied, '{cancel_orders}', (v_applied -> 'cancel_orders') || to_jsonb(v_ext));
        continue;
      end if;
      v_freeze := coalesce(v_order.external_meta, '{}'::jsonb) ? 'addon_merge';
      v_total := v_order.total_gross;
      -- Peruutus ei koske summaa. addon_merge-jäädytys säilyy (avain ja total_gross).
      update booking.orders
         set status = 'cancelled',
             cancelled_at = coalesce(cancelled_at, now()),
             external_meta = coalesce(external_meta, '{}'::jsonb) || jsonb_build_object('johku_removed', true)
       where id = v_order.id and external_source = 'johku'
         and total_gross is not distinct from v_total;
      if not found then
        perform booking._err('johku_sync_side_effect', 'addon_merge_total');
      end if;
      if v_freeze and (
           (select o.total_gross from booking.orders o where o.id = v_order.id) is distinct from v_total
           or not ((select o.external_meta from booking.orders o where o.id = v_order.id) ? 'addon_merge')
         ) then
        perform booking._err('johku_sync_side_effect', 'addon_merge_total');
      end if;
      v_applied := jsonb_set(v_applied, '{cancel_orders}', (v_applied -> 'cancel_orders') || to_jsonb(v_ext));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      v_code := case when v_state = 'BK001' then coalesce(nullif(v_detail, ''), 'row_rejected') else 'row_rejected' end;
      v_review := v_review || jsonb_build_array(jsonb_build_object('kind', 'order', 'external_id', coalesce(v_ext, '?'), 'code', v_code));
    end;
  end loop;

  if (select count(*) from booking.payments) <> v_pay_n then perform booking._err('johku_sync_side_effect', 'payments'); end if;
  if (select count(*) from booking.receipts) <> v_rec_n then perform booking._err('johku_sync_side_effect', 'receipts'); end if;
  if (select count(*) from booking.email_outbox) <> v_mail_n then perform booking._err('johku_sync_side_effect', 'email_outbox'); end if;
  if (select count(*) from booking.accounting_outbox) <> v_acct_n then perform booking._err('johku_sync_side_effect', 'accounting_outbox'); end if;
  if (select count(*) from booking.refunds) <> v_ref_n then perform booking._err('johku_sync_side_effect', 'refunds'); end if;
  if (select count(*) from booking.gift_cards) <> v_gc_n then perform booking._err('johku_sync_side_effect', 'gift_cards'); end if;
  if (select count(*) from booking.gift_card_ledger) <> v_gcl_n then perform booking._err('johku_sync_side_effect', 'gift_card_ledger'); end if;
  select count(*) into v_hidden2 from booking.reservations where hidden_at is not null;
  select count(*) into v_merged2 from booking.reservations
   where external_meta ? 'merged_into' or (external_meta -> 'model') ? 'merged_into_package';
  select count(*) into v_frozen2 from booking.orders where external_meta ? 'addon_merge';
  select count(*) into v_addon2 from booking.order_items where kind = 'addon';
  if v_hidden2 < v_hidden or v_merged2 < v_merged or v_frozen2 < v_frozen or v_addon2 < v_addon_n then
    perform booking._err('johku_sync_unhide', 'guard count dropped');
  end if;

  -- Yksi audit-rivi per apply. Ei vanhaa/uutta asiakas- tai tilausriviä (henkilötietoja).
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (
    null,
    coalesce(booking._jwt_role(), 'service_role'),
    'johku_sync_runs',
    v_run,
    'johku_sync',
    jsonb_build_object(
      'run_id', v_run,
      'customers', jsonb_array_length(v_applied -> 'customers'),
      'orders', jsonb_array_length(v_applied -> 'orders'),
      'items', jsonb_array_length(v_applied -> 'items'),
      'reservations', jsonb_array_length(v_applied -> 'reservations'),
      'cancel_orders', jsonb_array_length(v_applied -> 'cancel_orders'),
      'cancel_reservations', jsonb_array_length(v_applied -> 'cancel_reservations'),
      'skipped', jsonb_array_length(v_skipped),
      'review', jsonb_array_length(v_review)
    )
  );

  return jsonb_build_object('ok', true, 'applied', v_applied, 'skipped', v_skipped, 'review', v_review);
end $$;

revoke all on function booking.svc_johku_sync_state() from public, anon, authenticated;
revoke all on function booking.svc_johku_sync_log(jsonb) from public, anon, authenticated;
revoke all on function booking.svc_johku_sync_apply(jsonb) from public, anon, authenticated;
grant execute on function booking.svc_johku_sync_state() to service_role;
grant execute on function booking.svc_johku_sync_log(jsonb) to service_role;
grant execute on function booking.svc_johku_sync_apply(jsonb) to service_role;
