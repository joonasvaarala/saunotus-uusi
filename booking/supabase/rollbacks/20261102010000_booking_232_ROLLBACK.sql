-- Rollback booking_232: lahjakorttiraportti palaa booking_222-muotoon (ei activity-osiota).
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function booking.admin_report_gift_cards(p_filter text, p_format text default 'json', p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  rep jsonb; bal jsonb; v_from date; v_to date; v_body text := ''; v_cr text := E'\r\n'; el jsonb; bucket text; b jsonb;
begin
  perform booking._report_check(true);
  if p_filter is null or p_filter not in ('open', 'used', 'all') then perform booking._err('invalid_param', 'p_filter: open|used|all'); end if;
  if coalesce(p_format, 'json') not in ('json', 'csv') then perform booking._err('invalid_param', 'p_format: json|csv'); end if;
  v_to := coalesce(p_to, (timezone('Europe/Helsinki', now()))::date);
  v_from := coalesce(p_from, v_to);
  if v_to < v_from or v_to - v_from > 366 then perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)'); end if;
  rep := booking._gc_stock_report(p_filter);
  bal := booking._gc_period_balance(v_from, v_to);
  rep := jsonb_build_object(
    'filter', p_filter,
    'period', jsonb_build_object('from', v_from, 'to', v_to, 'tz', 'Europe/Helsinki', 'kind', 'giftcards'),
    'generated_at', coalesce(rep -> 'generated_at', to_jsonb(now())),
    'own', rep -> 'own',
    'balance', jsonb_build_object('native_paid', bal -> 'native_paid', 'native_complimentary', bal -> 'native_complimentary'),
    'statistics', jsonb_build_object('johku', coalesce(rep -> 'johku', '{}'::jsonb) || jsonb_build_object('balance', bal -> 'johku')));
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
  return jsonb_build_object('filename', format('lahjakortit_%s_%s.csv', v_to, p_filter), 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || 'osio;koodi;ostaja;paketti;alkuperainen;saldo;netto;alv_%;alv_eur;brutto;myyntipaiva;voimassa;tila;alv_kasittely' || v_cr || v_body);
end $$;

revoke all on function booking.admin_report_gift_cards(text, text, date, date) from public, anon, authenticated;
grant execute on function booking.admin_report_gift_cards(text, text, date, date) to service_role, authenticated;

comment on function booking.admin_report_gift_cards(text, text, date, date) is
  'booking_222: omat lahjakortit ja jakson saldon muutos. Johku vain statistics.johku. CSV ja oletusosio ilman Johkua.';

drop function if exists booking._gc_period_activity(date, date);
drop function if exists booking._gc_activity_csv_source(text);
