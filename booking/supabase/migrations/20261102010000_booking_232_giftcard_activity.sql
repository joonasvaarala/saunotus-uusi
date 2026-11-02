-- booking_232: lahjakorttiraportin jakson aktiviteetti lähteittäin.
-- Omat maksetut (kirjanpito), omat maksuttomat, Johku ja kumppanilunastukset
-- (voucher_claims.status = redeemed + payments.method partner_voucher*).
-- Kumppanin myynti ei ole meidän myyntiä. Kumppanirivi on kirjanpitoa vain, jos
-- voucher_claims.partner_voucher_accounted on jo true (oletus false = vain tiedoksi).
-- Myyntiraporttia, myynti-CSV:tä ja ALV-laskentaa ei muuteta.
-- Rollback: rollbacks/20261102010000_booking_232_ROLLBACK.sql

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function booking._gc_activity_csv_source(p_source text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_source
    when 'native_paid' then 'oma_maksettu'
    when 'native_complimentary' then 'oma_maksuton'
    when 'johku' then 'johku_tiedoksi'
    else 'kumppani_' || coalesce(nullif(p_source, ''), 'muu') end
$$;

revoke all on function booking._gc_activity_csv_source(text) from public, anon, authenticated;
grant execute on function booking._gc_activity_csv_source(text) to service_role;

comment on function booking._gc_activity_csv_source(text) is
  'booking_232: lahjakortti-CSV:n lähdekoodi. Johku on johku_tiedoksi, ei kirjanpito-osio.';

create or replace function booking._gc_period_activity(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  bal jsonb;
  accounted boolean;
  rows jsonb := '[]'::jsonb;
  partners jsonb := '[]'::jsonb;
  bucket text;
  b jsonb;
  ev jsonb;
  sold_n int;
  used_n int;
  exp_n int;
  totals jsonb;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  bal := booking._gc_period_balance(p_from, p_to);
  accounted := booking._gc_flag('voucher_claims.partner_voucher_accounted');

  foreach bucket in array array['native_paid', 'native_complimentary', 'johku'] loop
    b := bal -> bucket;
    select coalesce(jsonb_agg(x.obj order by x.day, x.order_no nulls last, x.code_masked), '[]'::jsonb)
      into ev
      from (
        select (l.at at time zone 'Europe/Helsinki')::date as day,
               (select o.order_no from booking.orders o where o.id = coalesce(l.order_id, g.purchase_order_id)) as order_no,
               '****-****-' || right(g.code, 4) as code_masked,
               jsonb_build_object(
                 'kind', case when l.reason = 'opening_balance' then 'opening' else 'sale' end,
                 'date', (l.at at time zone 'Europe/Helsinki')::date,
                 'amount', round(l.delta, 2),
                 'code_masked', '****-****-' || right(g.code, 4),
                 'order_no', (select o.order_no from booking.orders o where o.id = coalesce(l.order_id, g.purchase_order_id)),
                 'value_card', false) as obj
          from booking.gift_card_ledger l
          join booking.gift_cards g on g.id = l.gift_card_id
         where l.at >= (p_from::timestamp at time zone 'Europe/Helsinki')
           and l.at < ((p_to + 1)::timestamp at time zone 'Europe/Helsinki')
           and l.reason in ('purchase', 'manual_issue', 'johku_purchase', 'opening_balance')
           and l.delta > 0
           and (case when g.source = 'johku' or g.accounting_origin = 'johku' then 'johku'
                     when g.complimentary then 'native_complimentary' else 'native_paid' end) = bucket
        union all
        select (l.at at time zone 'Europe/Helsinki')::date,
               (select o.order_no from booking.orders o where o.id = coalesce(l.order_id, (select p.order_id from booking.payments p where p.id = l.payment_id))),
               '****-****-' || right(g.code, 4),
               jsonb_build_object(
                 'kind', 'redemption',
                 'date', (l.at at time zone 'Europe/Helsinki')::date,
                 'amount', round(-l.delta, 2),
                 'code_masked', '****-****-' || right(g.code, 4),
                 'order_no', (select o.order_no from booking.orders o where o.id = coalesce(l.order_id, (select p.order_id from booking.payments p where p.id = l.payment_id))),
                 'value_card', false)
          from booking.gift_card_ledger l
          join booking.gift_cards g on g.id = l.gift_card_id
         where l.at >= (p_from::timestamp at time zone 'Europe/Helsinki')
           and l.at < ((p_to + 1)::timestamp at time zone 'Europe/Helsinki')
           and l.reason in ('redemption', 'johku_usage')
           and l.delta < 0
           and (case when g.source = 'johku' or g.accounting_origin = 'johku' then 'johku'
                     when g.complimentary then 'native_complimentary' else 'native_paid' end) = bucket
        union all
        select g.valid_to,
               (select o.order_no from booking.orders o where o.id = g.purchase_order_id),
               '****-****-' || right(g.code, 4),
               jsonb_build_object(
                 'kind', 'expiry',
                 'date', g.valid_to,
                 'amount', round(q.bal1, 2),
                 'code_masked', '****-****-' || right(g.code, 4),
                 'order_no', (select o.order_no from booking.orders o where o.id = g.purchase_order_id),
                 'value_card', false)
          from booking.gift_cards g
          join lateral (
            select coalesce((select l.balance_after from booking.gift_card_ledger l
                              where l.gift_card_id = g.id
                                and l.at < ((p_to + 1)::timestamp at time zone 'Europe/Helsinki')
                              order by l.at desc, l.id desc limit 1), 0) as bal1
          ) q on true
         where g.valid_to between p_from and p_to
           and q.bal1 > 0.004
           and (case when g.source = 'johku' or g.accounting_origin = 'johku' then 'johku'
                     when g.complimentary then 'native_complimentary' else 'native_paid' end) = bucket
      ) x;
    select count(*) into sold_n from jsonb_array_elements(ev) e where e ->> 'kind' in ('sale', 'opening');
    select count(*) into used_n from jsonb_array_elements(ev) e where e ->> 'kind' = 'redemption';
    select count(*) into exp_n from jsonb_array_elements(ev) e where e ->> 'kind' = 'expiry';
    rows := rows || jsonb_build_array(jsonb_build_object(
      'source', bucket,
      'group', case when bucket = 'johku' then 'johku' else 'own' end,
      'accounting', coalesce((b ->> 'accounting')::boolean, false),
      'sold_applicable', true,
      'balance_applicable', true,
      'sold_count', sold_n,
      'sold_gross', coalesce((b ->> 'sold')::numeric, 0),
      'redeemed_count', used_n,
      'redeemed_gross', coalesce((b ->> 'redeemed')::numeric, 0),
      'expired_count', exp_n,
      'expired_gross', coalesce((b ->> 'expired')::numeric, 0),
      'opening', coalesce((b ->> 'opening')::numeric, 0),
      'closing', coalesce((b ->> 'closing')::numeric, 0),
      'value_card_count', 0,
      'events', ev));
  end loop;

  with bounds as (
    select (p_from::timestamp at time zone 'Europe/Helsinki') as t0,
           ((p_to + 1)::timestamp at time zone 'Europe/Helsinki') as t1
  ), partner_ev as (
    select case c.source
             when 'elamyslahjat' then 'elamyslahjat'
             when 'kokemuskauppa' then 'kokemuskauppa'
             when 'offerilla' then 'offerilla'
             when 'kiitoskauppa' then 'kiitoskauppa'
             when 'partner_other' then 'partner_other'
             else 'partner_other' end as source,
           (coalesce(p.paid_at, c.resolved_at) at time zone 'Europe/Helsinki')::date as day,
           o.order_no,
           booking._vc_mask(c.code) as code_masked,
           case when p.id is not null and p.status in ('paid', 'partially_refunded', 'refunded') then p.amount
                else coalesce(c.amount, 0) end as amount,
           coalesce(c.value_card, false) as value_card
      from booking.voucher_claims c
      join booking.orders o on o.id = c.order_id
      left join booking.payments p on p.id = c.payment_id
      cross join bounds bd
     where c.status = 'redeemed'
       and coalesce(p.paid_at, c.resolved_at) >= bd.t0
       and coalesce(p.paid_at, c.resolved_at) < bd.t1
    union all
    select case p.method
             when 'partner_voucher_kokemuskauppa' then 'kokemuskauppa'
             when 'partner_voucher_offerilla' then 'offerilla'
             when 'partner_voucher_elamyslahjat' then 'elamyslahjat'
             else 'partner_voucher' end,
           (p.paid_at at time zone 'Europe/Helsinki')::date,
           o.order_no,
           null::text,
           p.amount,
           false
      from booking.payments p
      join booking.orders o on o.id = p.order_id
      cross join bounds bd
     where booking._is_partner_method(p.method)
       and p.status in ('paid', 'partially_refunded', 'refunded')
       and p.paid_at >= bd.t0 and p.paid_at < bd.t1
       and not exists (select 1 from booking.voucher_claims c where c.payment_id = p.id)
  )
  select coalesce(jsonb_agg(s.obj order by s.ord, s.source), '[]'::jsonb)
    into partners
    from (
      select source,
             coalesce(array_position(array['elamyslahjat', 'kokemuskauppa', 'offerilla', 'kiitoskauppa', 'partner_other', 'partner_voucher'], source), 99) as ord,
             jsonb_build_object(
               'source', source,
               'group', 'partner',
               'accounting', accounted,
               'sold_applicable', false,
               'balance_applicable', false,
               'redeemed_count', count(*),
               'redeemed_gross', round(coalesce(sum(amount), 0), 2),
               'value_card_count', count(*) filter (where value_card),
               'events', coalesce(jsonb_agg(jsonb_build_object(
                   'kind', 'redemption',
                   'date', day,
                   'amount', round(amount, 2),
                   'code_masked', code_masked,
                   'order_no', order_no,
                   'value_card', value_card) order by day, order_no nulls last, code_masked), '[]'::jsonb)) as obj
        from partner_ev
       group by source
    ) s;

  rows := rows || partners;
  select jsonb_build_object(
    'sold_count', coalesce(sum((r ->> 'sold_count')::int) filter (where coalesce((r ->> 'sold_applicable')::boolean, false)), 0),
    'sold_gross', coalesce(round(sum((r ->> 'sold_gross')::numeric) filter (where coalesce((r ->> 'sold_applicable')::boolean, false)), 2), 0),
    'redeemed_count', coalesce(sum((r ->> 'redeemed_count')::int), 0),
    'redeemed_gross', coalesce(round(sum((r ->> 'redeemed_gross')::numeric), 2), 0),
    'expired_count', coalesce(sum((r ->> 'expired_count')::int) filter (where coalesce((r ->> 'balance_applicable')::boolean, false)), 0),
    'expired_gross', coalesce(round(sum((r ->> 'expired_gross')::numeric) filter (where coalesce((r ->> 'balance_applicable')::boolean, false)), 2), 0),
    'opening', coalesce(round(sum((r ->> 'opening')::numeric) filter (where coalesce((r ->> 'balance_applicable')::boolean, false)), 2), 0),
    'closing', coalesce(round(sum((r ->> 'closing')::numeric) filter (where coalesce((r ->> 'balance_applicable')::boolean, false)), 2), 0),
    'accounting_closing', coalesce(round(sum((r ->> 'closing')::numeric) filter (where coalesce((r ->> 'accounting')::boolean, false) and coalesce((r ->> 'balance_applicable')::boolean, false)), 2), 0)
  ) into totals
  from jsonb_array_elements(rows) r;
  return jsonb_build_object('rows', rows, 'totals', totals, 'partner_accounted', accounted);
end
$fn$;

revoke all on function booking._gc_period_activity(date, date) from public, anon, authenticated;
grant execute on function booking._gc_period_activity(date, date) to service_role;

comment on function booking._gc_period_activity(date, date) is
  'booking_232: jakson lahjakorttiaktiviteetti lähteittäin. Omat ja Johku ledgeristä, kumppanit voucher_claims(redeemed) ja partner_voucher-maksuista. Koodi vain maskattuna. Ei muuta myyntiä eikä ALV:tä.';

create or replace function booking.admin_report_gift_cards(p_filter text, p_format text default 'json', p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  rep jsonb; bal jsonb; act jsonb; v_from date; v_to date; v_body text := ''; v_cr text := E'\r\n'; el jsonb; ev jsonb; bucket text; b jsonb;
begin
  perform booking._report_check(true);
  if p_filter is null or p_filter not in ('open', 'used', 'all') then perform booking._err('invalid_param', 'p_filter: open|used|all'); end if;
  if coalesce(p_format, 'json') not in ('json', 'csv') then perform booking._err('invalid_param', 'p_format: json|csv'); end if;
  v_to := coalesce(p_to, (timezone('Europe/Helsinki', now()))::date);
  v_from := coalesce(p_from, v_to);
  if v_to < v_from or v_to - v_from > 366 then perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)'); end if;
  rep := booking._gc_stock_report(p_filter);
  bal := booking._gc_period_balance(v_from, v_to);
  act := booking._gc_period_activity(v_from, v_to);
  rep := jsonb_build_object(
    'filter', p_filter,
    'period', jsonb_build_object('from', v_from, 'to', v_to, 'tz', 'Europe/Helsinki', 'kind', 'giftcards'),
    'generated_at', coalesce(rep -> 'generated_at', to_jsonb(now())),
    'own', rep -> 'own',
    'balance', jsonb_build_object('native_paid', bal -> 'native_paid', 'native_complimentary', bal -> 'native_complimentary'),
    'statistics', jsonb_build_object('johku', coalesce(rep -> 'johku', '{}'::jsonb) || jsonb_build_object('balance', bal -> 'johku')),
    'activity', act);
  if p_format is distinct from 'csv' then return rep; end if;
  for el in select * from jsonb_array_elements(rep -> 'own' -> 'rows') loop
    v_body := v_body || concat_ws(';', 'oma', booking._csv(el ->> 'code_masked'), booking._csv(el ->> 'buyer'), booking._csv(el ->> 'package'),
      booking._csvmoney(coalesce((el ->> 'initial')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'balance')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)),
      booking._csvnum(coalesce((el ->> 'vat_rate')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)),
      booking._csv(el ->> 'sold_on'), booking._csv(el ->> 'valid_to'), booking._csv(el ->> 'status'), booking._csv(el ->> 'vat_treatment')) || v_cr;
  end loop;
  foreach bucket in array array['oma_myynnissa', 'oma_maksuton'] loop
    b := case bucket when 'oma_myynnissa' then rep -> 'own' -> 'at_sale' else rep -> 'own' -> 'complimentary' end;
    v_body := v_body || concat_ws(';', 'yhteenveto', bucket, b ->> 'count', '',
      booking._csvmoney((b ->> 'initial')::numeric), booking._csvmoney((b ->> 'balance')::numeric), booking._csvmoney((b ->> 'net')::numeric),
      '', booking._csvmoney((b ->> 'vat')::numeric), booking._csvmoney((b ->> 'gross')::numeric), '', '', '', '') || v_cr;
  end loop;
  foreach bucket in array array['native_paid', 'native_complimentary'] loop
    b := rep -> 'balance' -> bucket;
    v_body := v_body || concat_ws(';', 'saldo', case bucket when 'native_paid' then 'oma_maksettu' else 'oma_maksuton' end,
      'alkusaldo', '', '', '', '', booking._csvmoney(coalesce((b ->> 'opening')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'saldo', case bucket when 'native_paid' then 'oma_maksettu' else 'oma_maksuton' end,
      'myyty', '', '', '', '', booking._csvmoney(coalesce((b ->> 'sold')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'saldo', case bucket when 'native_paid' then 'oma_maksettu' else 'oma_maksuton' end,
      'lunastettu', '', '', '', '', booking._csvmoney(coalesce((b ->> 'redeemed')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'saldo', case bucket when 'native_paid' then 'oma_maksettu' else 'oma_maksuton' end,
      'muu', '', '', '', '', booking._csvmoney(coalesce((b ->> 'other')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'saldo', case bucket when 'native_paid' then 'oma_maksettu' else 'oma_maksuton' end,
      'vanhentunut', '', '', '', '', booking._csvmoney(coalesce((b ->> 'expired')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'saldo', case bucket when 'native_paid' then 'oma_maksettu' else 'oma_maksuton' end,
      'loppusaldo', '', '', '', '', booking._csvmoney(coalesce((b ->> 'closing')::numeric, 0))) || v_cr;
  end loop;
  v_body := v_body || 'aktiviteetti_otsikko;lahde;merkinta;myyty_kpl;myyty_eur;kaytetty_kpl;kaytetty_eur;vanhentunut_kpl;vanhentunut_eur;alkusaldo;loppusaldo' || v_cr;
  for el in select value from jsonb_array_elements(act -> 'rows') loop
    v_body := v_body || concat_ws(';', 'aktiviteetti', booking._gc_activity_csv_source(el ->> 'source'),
      case when coalesce((el ->> 'accounting')::boolean, false) then 'kirjanpito' else 'tiedoksi' end,
      case when coalesce((el ->> 'sold_applicable')::boolean, false) then coalesce(el ->> 'sold_count', '0') else '' end,
      case when coalesce((el ->> 'sold_applicable')::boolean, false) then booking._csvmoney(coalesce((el ->> 'sold_gross')::numeric, 0)) else '' end,
      coalesce(el ->> 'redeemed_count', '0'),
      booking._csvmoney(coalesce((el ->> 'redeemed_gross')::numeric, 0)),
      case when coalesce((el ->> 'balance_applicable')::boolean, false) then coalesce(el ->> 'expired_count', '0') else '' end,
      case when coalesce((el ->> 'balance_applicable')::boolean, false) then booking._csvmoney(coalesce((el ->> 'expired_gross')::numeric, 0)) else '' end,
      case when coalesce((el ->> 'balance_applicable')::boolean, false) then booking._csvmoney(coalesce((el ->> 'opening')::numeric, 0)) else '' end,
      case when coalesce((el ->> 'balance_applicable')::boolean, false) then booking._csvmoney(coalesce((el ->> 'closing')::numeric, 0)) else '' end) || v_cr;
    for ev in select value from jsonb_array_elements(coalesce(el -> 'events', '[]'::jsonb)) loop
      v_body := v_body || concat_ws(';', 'tapahtuma', booking._gc_activity_csv_source(el ->> 'source'),
        ev ->> 'kind', ev ->> 'date', coalesce(ev ->> 'order_no', ''),
        booking._csvmoney(coalesce((ev ->> 'amount')::numeric, 0)), booking._csv(ev ->> 'code_masked'),
        case when coalesce((ev ->> 'value_card')::boolean, false) then 'arvolahjakortti' else '' end) || v_cr;
    end loop;
  end loop;
  b := act -> 'totals';
  v_body := v_body || concat_ws(';', 'yhteensa', 'kaikki', 'ei_kirjanpitosumma',
    coalesce(b ->> 'sold_count', '0'), booking._csvmoney(coalesce((b ->> 'sold_gross')::numeric, 0)),
    coalesce(b ->> 'redeemed_count', '0'), booking._csvmoney(coalesce((b ->> 'redeemed_gross')::numeric, 0)),
    coalesce(b ->> 'expired_count', '0'), booking._csvmoney(coalesce((b ->> 'expired_gross')::numeric, 0)),
    booking._csvmoney(coalesce((b ->> 'opening')::numeric, 0)), booking._csvmoney(coalesce((b ->> 'closing')::numeric, 0))) || v_cr;
  return jsonb_build_object('filename', format('lahjakortit_%s_%s.csv', v_to, p_filter), 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || 'osio;koodi;ostaja;paketti;alkuperainen;saldo;netto;alv_%;alv_eur;brutto;myyntipaiva;voimassa;tila;alv_kasittely' || v_cr || v_body);
end $$;

revoke all on function booking.admin_report_gift_cards(text, text, date, date) from public, anon, authenticated;
grant execute on function booking.admin_report_gift_cards(text, text, date, date) to service_role, authenticated;

comment on function booking.admin_report_gift_cards(text, text, date, date) is
  'booking_232: oma saldo ja jakson aktiviteetti (omat, Johku, kumppanit). Johku ja kumppanit vain tiedoksi, paitsi jos partner_voucher_accounted. Myynti-CSV ja ALV ennallaan. CSV: tapahtumarivit mukana, kirjanpito-osio ilman Johku-varastoa.';
