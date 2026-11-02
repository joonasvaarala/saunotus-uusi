-- t238: booking_238. Monipäiväisen kuitin aika alusta loppuun. Sama päivä säilyttää vanhan muodon.
-- Ajo migraatioiden jälkeen. Lopussa RAISE 'TESTRESULT pass=N fail=M' ja ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';
select set_config('t238.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t238.log', coalesce(current_setting('t238.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

do $t$
declare
  now_ts timestamptz := '2026-11-02 10:00:00+00';
  fi text; en text; yr text; same text; miss text;
  body text; snap jsonb; log text; np int; nf int;
begin
  fi := booking._when_range('2026-11-30 10:30:00+00', '2026-12-04 14:00:00+00', 'fi', now_ts);
  en := booking._when_range('2026-11-30 10:30:00+00', '2026-12-04 14:00:00+00', 'en', now_ts);
  yr := booking._when_range('2026-12-30 10:30:00+00', '2027-01-02 14:00:00+00', 'fi', now_ts);
  same := booking._when_range('2026-11-14 14:00:00+00', '2026-11-14 17:00:00+00', 'fi', now_ts);
  miss := booking._when_range('2026-11-30 10:30:00+00', null, 'fi', now_ts);
  perform pg_temp.ck(fi = 'ma 30.11. klo 12.30 – pe 4.12.2026 klo 16.00', 'A1 sama vuosi FI');
  perform pg_temp.ck(en = 'Mon 30 Nov 12:30 – Fri 4 Dec 2026 16:00', 'A2 sama vuosi EN');
  perform pg_temp.ck(yr = 'ke 30.12.2026 klo 12.30 – la 2.1.2027 klo 16.00', 'A3 vuodenvaihde');
  perform pg_temp.ck(same = 'la 14.11. klo 16.00–19.00', 'A4 sama päivä');
  perform pg_temp.ck(miss = 'ma 30.11. klo 12.30', 'A5 puuttuva loppu');
  perform pg_temp.ck(booking._when_range(null, '2026-12-04 14:00:00+00', 'fi', now_ts) = '', 'A6 puuttuva alku');

  snap := jsonb_build_object(
    'locale', 'fi', 'document', 'receipt', 'receipt_no', 'T-238', 'issued_local', '2.11.2026 12:00', 'order_no', 1,
    'seller', jsonb_build_object('name', 'S', 'legal_name', 'Havuhattu Oy', 'business_id', '1', 'vat_id', 'FI1'),
    'payment', jsonb_build_object('method_label', 'Kortti'),
    'lines', jsonb_build_array(
      jsonb_build_object('description', 'Kurssi', 'quantity', 1, 'line_gross', 200, 'line_net', 159.36, 'vat_rate', 25.5,
        'starts_at', '2032-11-30T10:30:00Z', 'ends_at', '2032-12-04T14:00:00Z'),
      jsonb_build_object('description', 'Vuoro', 'quantity', 1, 'line_gross', 29, 'line_net', 23.11, 'vat_rate', 25.5,
        'starts_at', '2032-11-30T14:00:00Z', 'ends_at', '2032-11-30T16:00:00Z')),
    'vat', jsonb_build_array(jsonb_build_object('rate', 25.5, 'net', 182.47, 'vat', 46.53, 'gross', 229)),
    'total_gross', 229, 'total_vat', 46.53, 'total_net', 182.47, 'total_paid', 229);
  body := booking._receipt_text(snap);
  perform pg_temp.ck(position('ti 30.11.2032 klo 12.30 – la 4.12.2032 klo 16.00' in body) > 0, 'B1 kuitin monipäiväinen väli');
  perform pg_temp.ck(position('30.11.2032 16:00–18:00' in body) > 0, 'B2 yksipäiväinen rivi ennallaan');
  perform pg_temp.ck(position('229,00' in body) > 0 and position('25,5' in body) > 0, 'B3 summa ja ALV ennallaan');

  log := current_setting('t238.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end
$t$;
rollback;
