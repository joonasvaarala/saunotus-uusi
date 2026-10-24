-- booking_166: saunarituaali yleisen vuoron lisäpalveluna (kauppa: lisäpalvelut-vaihe).
-- Väliaikainen versio 20261024202015 (tuotannon versio voi olla eri; Bottiavustus ajaa). Ei public-skeemaa. Hinnat, ALV, slugit ja URLit ennallaan.
--
-- Tuote: kb.products 8 'Saunotusrituaali' (pelkkä rituaali, 20 €/hlö, ALV 25,5 %, 20 min, 1–6 hlö; product_config: Rauni + rituaalipooli).
--   Ei kb 7:ää (paketti: rituaali + savusaunavuoro). Tuote vaihdettavissa asetuksella ritual_addon.product_id.
-- Asetus booking.settings 'ritual_addon' (jsonb, oletus päällä): enabled (päälle/pois-kytkin), product_id, aikasäännön osat
--   (before_min, at_start, first_after_min, step_min, at_end), session_product_ids (null = kaikki kelpaavat yleiset vuorot), horizon_days (null = ei rajaa).
-- Aikasääntö yhdessä paikassa: booking._ritual_addon_starts(alku, loppu). Oletus: alku − 30 min, alku, alku + 30 min ja siitä tunnin välein
--   (kun < loppu), loppu. Vuoro 16.00–18.00 → 15.30, 16.00, 16.30, 17.30, 18.00. Ajat timestamptz (Europe/Helsinki-vuoron ajoista), istunnon TZ ei vaikuta.
-- Saatavuus: booking.public_ritual_addon(p_rule_id, p_date, p_persons) → vain ajat, joihin oikeasti mahtuu (sama moottori kuin rituaalin
--   omassa varauksessa: _treatment_plan_status/_plan_legs = aukiolo, blokit, Raunin ristiriidat, rituaalipooli, Lovi, saunottajat;
--   lisäksi verkon ehdot: lead-aika, tuotteen public_weekdays (la–su), _public_shift_day_open). Ei aikoja → available=false → kauppa piilottaa.
--   Rituaalin allowed_starts (16.00/16.30/17.00) ja hoitojen 14 pv:n horisontti eivät koske lisäpalvelua.
-- Varaus: public_create_booking / public_create_booking_code p_addons-elementti {"ritual_start": "<ISO + aikavyöhyke>", "quantity": henkilöt}
--   → _attach_addons → _ritual_addon_attach: tarkistus ja lukitus palvelimella (aikalista, kapasiteetti triggereissä), hinta _treatment_price,
--   oma tilausrivi (kind reservation, price_breakdown.ritual_addon = true) + varaus samaan tilaukseen, parent_reservation_id = vuoron varaus,
--   sama tila ja pito kuin vuorolla. Alennuskoodin esikatselu (public_preview_code) laskee rituaalirivin samoin. Vuosikortti: ei lisäpalveluita (ennallaan).
-- Peruutus / siirto (trigger reservations_ritual_addon_parent): vuoro perutaan → rituaali perutaan (cancel_reason ritual_addon_parent_cancelled);
--   pito vanhenee → rituaali vanhenee; odottava vahvistetaan → rituaali vahvistetaan; vuoron alkuaika siirtyy (henkilökunta) → rituaali siirtyy
--   saman verran, ja jos se ei mahdu, koko muutos perutaan virheellä ritual_addon_move. Henkilömäärän muutos ei muuta rituaalia.
--   Asiakkaan verkkomuutos: tilauksessa on kaksi vahvistettua varausta → public_change_booking / can_change = false (olemassa oleva sääntö) → muutos
--   sähköpostilla. Peruutuksen palautus (_reservation_refund_plan) sisältää mukana peruuntuvan rituaalin rivin.
--   reservations_time_window: rituaalilapsen alkuajaksi kelpaa vanhemman vuoron aikalistan aika.
--   public_get_booking: items[].ritual_addon + has_ritual_addon; rituaali listataan vuoron jälkeen (items[0] = vuoro).
--
-- Vartija: korvattavien funktioiden md5(pg_get_functiondef) on oltava tuotannon (luettu sxbofnuisemspgquoxyv 24.10.2026) tai jo tämän migraation,
-- muuten ajo keskeytyy eikä mitään muuteta. Uudelleenajettava. Rollback palauttaa tuotannon määrittelyt täsmälleen:
--   booking._attach_addons(bigint,jsonb): 6a780e8e00229ff273a321591f197541 -> 319cac689b7c883bbba857af6b254a3f
--   booking._reservation_refund_plan(bigint): cb44c682ac0095617fe20b297b0cdac3 -> a22952905fc68f119427f7fd4e6025fa
--   booking.public_get_booking(uuid): a155cd472c356c09e595cbda46b4dada -> 778f1024006308d0dcd879ef9428ed00
--   booking.public_preview_code(text,bigint,date,integer,jsonb,text,text): fec859d04960f42d79412bbdf7dc6561 -> 4816fbaf5149e501a128aed40f2bf505
--   booking.reservations_time_window(): 023b689b0366602ab32738b7821dcc16 -> 4bff7a9af49ade40e5a953eaeea03547
-- Uudet: _ritual_addon_cfg, _ritual_addon_starts, _is_ritual_addon_item, _ritual_addon_session_ok, _ritual_addon_fit, _ritual_addon_start_ok,
--   _ritual_addon_attach, _ritual_addon_move, _ritual_addon_parent_trg, public_ritual_addon (anon/authenticated); trigger reservations_ritual_addon_parent.
-- Rollback: rollbacks/20261024202015_booking_166_ROLLBACK.sql. Testi: tests/t166_ritual_addon.sql (paikallinen PG17).
set local lock_timeout = '5s';


do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._attach_addons(bigint,jsonb)'::regprocedure));
  if v not in ('6a780e8e00229ff273a321591f197541', '319cac689b7c883bbba857af6b254a3f') then ok := false; msg := msg || ' _attach_addons=' || v; end if;
  v := md5(pg_get_functiondef('booking._reservation_refund_plan(bigint)'::regprocedure));
  if v not in ('cb44c682ac0095617fe20b297b0cdac3', 'a22952905fc68f119427f7fd4e6025fa') then ok := false; msg := msg || ' _reservation_refund_plan=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_get_booking(uuid)'::regprocedure));
  if v not in ('a155cd472c356c09e595cbda46b4dada', '778f1024006308d0dcd879ef9428ed00') then ok := false; msg := msg || ' public_get_booking=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure));
  -- e8fe514b… = booking_171 (tuotannossa 20261024212241) on jo ajettu: hyväksytään, ja uudelleenajo palauttaa booking_171:n määrittelyn lopussa
  if v not in ('fec859d04960f42d79412bbdf7dc6561', '4816fbaf5149e501a128aed40f2bf505', 'e8fe514b4ec9db4043d388e5547f94ad') then ok := false; msg := msg || ' public_preview_code=' || v; end if;
  perform set_config('booking.m166_keep_preview', case when v = 'e8fe514b4ec9db4043d388e5547f94ad'
    then pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure) else '' end, true);
  v := md5(pg_get_functiondef('booking.reservations_time_window()'::regprocedure));
  if v not in ('023b689b0366602ab32738b7821dcc16', '4bff7a9af49ade40e5a953eaeea03547') then ok := false; msg := msg || ' reservations_time_window=' || v; end if;
  if not ok then raise exception 'booking_166: korvattavien funktioiden md5 ei vastaa tuotantoa (%); mitään ei muutettu', msg; end if;
end $g$;

-- Asetus (oletus päällä). Olemassa olevaa arvoa ei ylikirjoiteta.
insert into booking.settings(key, value, description, is_public)
values ('ritual_addon',
        '{"enabled": true, "product_id": 8, "before_min": 30, "at_start": true, "first_after_min": 30, "step_min": 60, "at_end": true, "session_product_ids": null, "horizon_days": null}'::jsonb,
        'booking_166: saunarituaali yleisen vuoron lisäpalveluna. enabled = päälle/pois; product_id = rituaalituote (kb 8); aikasääntö: before_min (alku − min), at_start, first_after_min + step_min (alku + 30, + 90, … < loppu), at_end; session_product_ids = vuorotuotteet (null = kaikki yleiset); horizon_days = max päivää eteenpäin (null = vuoron horisontti)',
        false)
on conflict (key) do nothing;


-- ---------------------------------------------------------------------------------------------------------------
-- Uudet funktiot
-- ---------------------------------------------------------------------------------------------------------------

-- Asetus booking.settings 'ritual_addon' + oletukset. Puuttuva avain = oletusarvo. enabled = päälle/pois-kytkin.
create or replace function booking._ritual_addon_cfg()
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select '{"enabled": true, "product_id": 8, "before_min": 30, "at_start": true, "first_after_min": 30, "step_min": 60, "at_end": true, "session_product_ids": null, "horizon_days": null}'::jsonb
         || coalesce((select s.value from booking.settings s where s.key = 'ritual_addon' and jsonb_typeof(s.value) = 'object'), '{}'::jsonb)
$function$;

-- AIKASÄÄNTÖ (yksi paikka): rituaalin mahdolliset alkuajat vuoron alun ja lopun suhteen.
-- Oletus (asetus ritual_addon): before_min 30 → alku − 30 min; at_start → alku; first_after_min 30 + step_min 60 → alku + 30, + 90, … kun < loppu; at_end → loppu.
-- Esim. vuoro 16.00–18.00 → 15.30, 16.00, 16.30, 17.30, 18.00. Ajat ovat absoluuttisia (timestamptz), joten istunnon aikavyöhyke ei vaikuta.
-- Arvon null (before_min / first_after_min) tai false (at_start / at_end) saa kohdan pois.
create or replace function booking._ritual_addon_starts(p_start timestamptz, p_end timestamptz)
 returns setof timestamptz
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare c jsonb := booking._ritual_addon_cfg(); v_b int; v_f int; v_s int; t timestamptz; v_out timestamptz[] := '{}';
begin
  if p_start is null or p_end is null or p_end <= p_start then return; end if;
  v_b := nullif(c ->> 'before_min', '')::int; v_f := nullif(c ->> 'first_after_min', '')::int; v_s := nullif(c ->> 'step_min', '')::int;
  if v_b is not null and v_b > 0 then v_out := v_out || (p_start - make_interval(mins => v_b)); end if;
  if coalesce((c ->> 'at_start')::boolean, false) then v_out := v_out || p_start; end if;
  if v_f is not null and v_f >= 0 then
    t := p_start + make_interval(mins => v_f);
    while t < p_end and cardinality(v_out) < 48 loop
      v_out := v_out || t;
      exit when coalesce(v_s, 0) <= 0;
      t := t + make_interval(mins => v_s);
    end loop;
  end if;
  if coalesce((c ->> 'at_end')::boolean, false) then v_out := v_out || p_end; end if;
  return query select distinct u from unnest(v_out) u order by 1;
end $function$;

-- Onko tilausrivi vuoron lisäpalveluna varattu saunarituaali (price_breakdown.ritual_addon = true)
create or replace function booking._is_ritual_addon_item(p_item_id bigint)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select coalesce((select (i.price_breakdown ->> 'ritual_addon')::boolean from booking.order_items i where i.id = p_item_id), false)
$function$;

-- Voiko vuorosäännön vuoroon liittää rituaalin: aktiivinen yleinen (shared) tavallinen vuoro, ei tapahtuma, ei rituaalituote itse,
-- ei tuote/vuoro, jossa rituaali on jo mukana (rituaalipooli, esim. kb 7), ja tuote asetuksen session_product_ids-listalla (null = kaikki).
create or replace function booking._ritual_addon_session_ok(p_rule_id bigint)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  with c as (select booking._ritual_addon_cfg() v)
  select exists (
    select 1 from booking.schedule_rules r join kb.products p on p.id = r.product_id, c
     where r.id = p_rule_id and r.active and r.mode = 'shared' and coalesce(r.kind, 'regular') = 'regular'
       and r.product_id is distinct from nullif(c.v ->> 'product_id', '')::bigint
       and coalesce(p.category, '') <> 'event'
       and (jsonb_typeof(c.v -> 'session_product_ids') is distinct from 'array'
            or exists (select 1 from jsonb_array_elements_text(c.v -> 'session_product_ids') x where x = r.product_id::text))
       and not booking._is_ritual(coalesce((select array_agg(rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id = r.id), '{}'::bigint[]))
       and not exists (select 1 from booking.product_space_rules s join booking.resources x on x.id = s.pool_id and x.is_ritual_pool where s.product_id = r.product_id))
$function$;

-- Mahtuuko rituaali (asetuksen tuote) alkamaan p_start p_persons henkilölle. Palauttaa 'ok' / 'therapist_missing' / null (ei mahdu).
-- Resurssit samalla moottorilla kuin rituaalin oma varaus (_treatment_plan_status → _plan_legs: aukiolo, blokit, Raunin ristiriidat,
-- rituaalipoolin kapasiteetti, Lovi-säännöt, saunottajat; ei saunottajaa → therapist_missing kuten verkon hoitovarauksessa).
-- p_public: myös verkkomyynnin ehdot (public_treatment_min_lead_minutes, ei mennyttä päivää, tuotteen public_weekdays,
-- _public_shift_day_open, asetuksen horizon_days jos annettu). Rituaalin allowed_starts (16.00/16.30/17.00) ja hoitojen
-- 14 päivän horisontti eivät koske lisäpalvelua (aikasääntö on _ritual_addon_starts).
create or replace function booking._ritual_addon_fit(p_start timestamptz, p_persons integer, p_public boolean default true)
 returns text
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c jsonb := booking._ritual_addon_cfg(); v_prod bigint; pc booking.product_config; p kb.products; ls timestamp; v_lead int; v_h int; v_dur int;
begin
  v_prod := nullif(c ->> 'product_id', '')::bigint;
  if p_start is null or p_persons is null or p_persons < 1 or v_prod is null then return null; end if;
  select * into pc from booking.product_config where product_id = v_prod;
  select * into p from kb.products where id = v_prod and active;
  if pc.product_id is null or p.id is null or not pc.bookable or pc.lifecycle <> 'current' then return null; end if;
  if p_persons < greatest(coalesce(pc.min_persons, 1), 1) or p_persons > booking._treatment_max_persons(v_prod) then return null; end if;
  v_dur := coalesce(pc.duration_minutes, p.duration_minutes);
  if v_dur is null or v_dur <= 0 then return null; end if;
  if p_public then
    v_lead := coalesce((booking._setting('public_treatment_min_lead_minutes', '120'::jsonb) #>> '{}')::int, 120);
    if p_start < now() + make_interval(mins => v_lead) then return null; end if;
    ls := p_start at time zone booking._tz();
    if ls::date < (now() at time zone booking._tz())::date then return null; end if;
    v_h := nullif(c ->> 'horizon_days', '')::int;
    if v_h is not null and ls::date > (now() at time zone booking._tz())::date + v_h then return null; end if;
    if pc.public_weekdays is not null and not (extract(isodow from ls)::smallint = any (pc.public_weekdays)) then return null; end if;
    if not booking._public_shift_day_open(ls::date) then return null; end if;
  end if;
  return booking._treatment_plan_status(v_prod, p_start, p_start + make_interval(mins => v_dur), p_persons);
end $function$;

-- reservations_time_window-poikkeus: lapsivaraus on asetuksen rituaalituote, vanhempi on sääntöpohjainen yleinen vuoro
-- ja alkuaika on vanhemman (nykyisten) aikojen mukaisella listalla.
create or replace function booking._ritual_addon_start_ok(p_parent_id bigint, p_product_id bigint, p_start timestamptz)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select exists (
    select 1 from booking.reservations pr
     where pr.id = p_parent_id and pr.rule_id is not null and pr.mode = 'shared'
       and p_product_id = nullif(booking._ritual_addon_cfg() ->> 'product_id', '')::bigint
       and exists (select 1 from booking._ritual_addon_starts(pr.starts_at, pr.ends_at) t where t = p_start))
$function$;

-- Julkinen: rituaali lisäpalveluna valitulle vuorolle (sama vuoro kuin public_create_booking: p_rule_id + p_date + p_persons).
-- Palauttaa vain ajat, joihin mahtuu oikeasti vähintään 1 henkilö; max_persons = enintään vuoron henkilömäärä ja mitä mahtuu.
-- available = false → kauppa piilottaa lisäpalvelun.
create or replace function booking.public_ritual_addon(p_rule_id bigint, p_date date, p_persons integer default 1)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c jsonb := booking._ritual_addon_cfg(); v_prod bigint; p kb.products; pc booking.product_config; s record; v_n int; v_max int; v_min int; v_dur int;
  t timestamptz; k int; v_st text; v_times jsonb := '[]'::jsonb; v_prices jsonb := '{}'::jsonb; i int;
begin
  v_prod := nullif(c ->> 'product_id', '')::bigint;
  if not coalesce((c ->> 'enabled')::boolean, false) or v_prod is null then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'disabled', 'times', '[]'::jsonb);
  end if;
  select * into p from kb.products where id = v_prod and active;
  select * into pc from booking.product_config where product_id = v_prod;
  if p.id is null or pc.product_id is null or not pc.bookable or pc.lifecycle <> 'current' then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'product_unavailable', 'times', '[]'::jsonb);
  end if;
  if p_rule_id is null or p_date is null or not booking._ritual_addon_session_ok(p_rule_id) then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'not_eligible', 'times', '[]'::jsonb);
  end if;
  v_n := least(greatest(coalesce(p_persons, 1), 1), 50);
  begin
    select * into s from booking._resolve_session(p_rule_id, p_date, v_n, true);
  exception when sqlstate 'BK001' then
    return jsonb_build_object('ok', true, 'available', false, 'reason', 'no_session', 'times', '[]'::jsonb);
  end;
  v_min := greatest(coalesce(pc.min_persons, 1), 1);
  v_max := least(v_n, booking._treatment_max_persons(v_prod));
  v_dur := coalesce(pc.duration_minutes, p.duration_minutes);
  if v_max >= v_min then
    for i in v_min .. v_max loop v_prices := v_prices || jsonb_build_object(i::text, round(booking._treatment_price(v_prod, i), 2)); end loop;
    for t in select x from booking._ritual_addon_starts(s.o_starts_at, s.o_ends_at) x loop
      k := v_max; v_st := null;
      while k >= v_min loop
        v_st := booking._ritual_addon_fit(t, k, true);
        exit when v_st is not null;
        k := k - 1;
      end loop;
      continue when v_st is null;
      v_times := v_times || jsonb_build_object('starts_at', t, 'ends_at', t + make_interval(mins => v_dur), 'max_persons', k,
        'label', to_char(t at time zone booking._tz(), 'HH24:MI'),
        'position', case when t < s.o_starts_at then 'before' when t = s.o_starts_at then 'start' when t >= s.o_ends_at then 'end' else 'during' end);
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'available', jsonb_array_length(v_times) > 0, 'reason', case when jsonb_array_length(v_times) = 0 then 'full' end,
    'product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price_type', p.price_type, 'unit_price', round(booking._treatment_price(v_prod, 1), 2),
    'prices', v_prices, 'vat_rate', p.vat_rate, 'duration_minutes', v_dur, 'min_persons', v_min, 'max_persons', greatest(v_max, 0),
    'session_starts_at', s.o_starts_at, 'session_ends_at', s.o_ends_at, 'times', v_times);
end $function$;

-- Lukitsee valitun rituaalin vuoron varaukseen (kutsuu _attach_addons): tarkistaa ajan ja kapasiteetin palvelimella,
-- luo tilausriville oman 'reservation'-rivin (hinta _treatment_price) ja varauksen rituaaliresurssille samaan tilaukseen,
-- parent_reservation_id = vuoron varaus, sama tila ja pito kuin vuorolla. Palauttaa rivin hinnan (lisätään tilauksen summaan kutsujassa).
create or replace function booking._ritual_addon_attach(p_res_id bigint, p_el jsonb)
 returns numeric
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c jsonb := booking._ritual_addon_cfg(); r booking.reservations; v_prod bigint; p kb.products; pc booking.product_config;
  v_txt text; v_start timestamptz; v_end timestamptz; v_q int; v_max int; v_st text; v_price numeric; v_item bigint; v_child booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_missing boolean := false; v_ecode text;
  v_off int; v_cmin int; v_pools bigint[];
begin
  select * into r from booking.reservations where id = p_res_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  v_prod := nullif(c ->> 'product_id', '')::bigint;
  if not coalesce((c ->> 'enabled')::boolean, false) or v_prod is null then
    perform booking._err('ritual_addon_unavailable', 'Saunarituaali ei ole nyt varattavissa');
  end if;
  if r.rule_id is null or r.mode <> 'shared' or not booking._ritual_addon_session_ok(r.rule_id) then
    perform booking._err('ritual_addon_not_allowed', 'Saunarituaalin voi lisätä vain yleiselle vuorolle');
  end if;
  select * into p from kb.products where id = v_prod and active;
  select * into pc from booking.product_config where product_id = v_prod;
  if p.id is null or pc.product_id is null then perform booking._err('ritual_addon_unavailable', 'Saunarituaali ei ole nyt varattavissa'); end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_txt := btrim(coalesce(p_el ->> 'ritual_start', ''));
  -- aika aina aikavyöhykkeen kanssa (tuotannon istunto on UTC): '…Z' tai '…+02:00' / '+0200' / '+02'
  if v_txt !~ '^\d{4}-\d\d-\d\d[T ]\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d(:?\d\d)?)$' then
    perform booking._err('ritual_addon_time', 'Saunarituaalin aika on virheellinen');
  end if;
  begin v_start := v_txt::timestamptz;
  exception when others then perform booking._err('ritual_addon_time', 'Saunarituaalin aika on virheellinen');
  end;
  v_max := least(r.persons, booking._treatment_max_persons(v_prod));
  if coalesce(p_el ->> 'quantity', '') !~ '^\d{1,3}$' or (p_el ->> 'quantity')::int < greatest(coalesce(pc.min_persons, 1), 1) or (p_el ->> 'quantity')::int > v_max then
    perform booking._err('ritual_addon_persons', format('Saunarituaaliin voi valita 1–%s henkilöä', greatest(v_max, 1)));
  end if;
  v_q := (p_el ->> 'quantity')::int;
  if not exists (select 1 from booking._ritual_addon_starts(r.starts_at, r.ends_at) t where t = v_start) then
    perform booking._err('ritual_addon_time', 'Saunarituaalin aika ei sovi valitulle vuorolle');
  end if;
  v_st := booking._ritual_addon_fit(v_start, v_q, true);
  if v_st is null then
    perform booking._err('ritual_addon_full', 'Valittu saunarituaalin aika ei ole enää vapaana – valitse toinen aika');
  end if;
  v_end := v_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes));

  begin
    for lp in select * from booking._plan_legs(v_prod, v_start, v_end, v_q) loop v_plan := array_append(v_plan, lp); end loop;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_ecode = pg_exception_detail;
    if v_ecode is distinct from 'no_therapist' then perform booking._err('ritual_addon_full', 'Valittu saunarituaalin aika ei ole enää vapaana – valitse toinen aika'); end if;
    v_plan := '{}'; v_missing := true;
    for lp in select * from booking._plan_legs(v_prod, v_start, v_end, v_q, null, false, null, true) loop v_plan := array_append(v_plan, lp); end loop;
  end;
  select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
  if v_prim.resource_id is null then perform booking._err('no_primary_leg', 'Tuotteelta puuttuu ensisijainen tila (product_space_rules leg 1)'); end if;
  v_off := (extract(epoch from (v_prim.claim_start - v_start)) / 60)::int;
  v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
  v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;

  v_price := round(booking._treatment_price(v_prod, v_q), 2);   -- palvelimen hinta (kb.products), asiakkaan lähettämää hintaa ei käytetä
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (r.order_id, p.id, p.name, 'reservation', 1, v_price, v_price, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', v_q, 'ritual_addon', true, 'parent_reservation_id', r.id,
                             'unit_price', round(booking._treatment_price(v_prod, 1), 2), 'name_en', p.name_en))
  returning id into v_item;
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status, hold_expires_at,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, created_by, therapist_missing)
  values (r.order_id, v_item, p.id, v_prim.resource_id, v_prim.mode, v_start, v_end, v_q, v_pools, r.status, r.hold_expires_at,
          false, v_off, v_cmin, r.id, r.created_by, v_missing)
  returning * into v_child;                                  -- triggerit: kapasiteetti (reservations_validate) + aikaikkuna (poikkeus yllä)
  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key, quota_exempt, rule_id)
    values (v_child.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key, false, lp.rule_id);
  end loop;
  return v_price;
end $function$;

-- Siirtää vuoron mukana olevan rituaalin uuteen alkuaikaan (legit suunnitellaan uudelleen, kapasiteetti tarkistetaan).
-- Ei mahdu → virhe 'ritual_addon_move' ja koko muutos (myös vuoron siirto) perutaan.
create or replace function booking._ritual_addon_move(p_child_id bigint, p_new_start timestamptz)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  x booking.reservations; v_end timestamptz; v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_missing boolean := false; v_ecode text; v_msg text;
begin
  select * into x from booking.reservations where id = p_child_id for update;
  if not found or x.starts_at = p_new_start then return; end if;
  v_end := p_new_start + (x.ends_at - x.starts_at);
  begin
    delete from booking.reservation_legs where reservation_id = x.id;
    update booking.reservations set starts_at = p_new_start, ends_at = v_end where id = x.id;
    begin
      for lp in select * from booking._plan_legs(x.product_id, p_new_start, v_end, x.persons, null, false, x.id) loop v_plan := array_append(v_plan, lp); end loop;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_ecode = pg_exception_detail;
      if v_ecode is distinct from 'no_therapist' then raise; end if;
      v_plan := '{}'; v_missing := true;
      for lp in select * from booking._plan_legs(x.product_id, p_new_start, v_end, x.persons, null, false, x.id, true) loop v_plan := array_append(v_plan, lp); end loop;
    end;
    for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
      insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key, quota_exempt, rule_id)
      values (x.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
              case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key, x.quota_exempt, lp.rule_id);
    end loop;
    if v_missing is distinct from x.therapist_missing then
      update booking.reservations set therapist_missing = v_missing,
             therapist_exception_at = case when v_missing then therapist_exception_at end,
             therapist_exception_by = case when v_missing then therapist_exception_by end,
             therapist_exception_note = case when v_missing then therapist_exception_note end
       where id = x.id;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_msg = message_text;
    perform booking._err('ritual_addon_move', 'Vuoron mukana varattua saunarituaalia (varaus #' || x.id || ') ei voi siirtää uuteen aikaan: ' || v_msg
                         || '. Peru tai siirrä rituaali ensin.');
  end;
end $function$;

-- Vuoron varauksen muutos → mukana olevat rituaalit seuraavat:
--   peruttu → rituaali perutaan (cancel_reason 'ritual_addon_parent_cancelled'); vanhentunut pito → odottava rituaali vanhenee;
--   odottava → vahvistettu → odottava rituaali vahvistetaan; alkuaika siirtyy → rituaali siirtyy saman verran (ei mahdu → koko muutos perutaan).
create or replace function booking._ritual_addon_parent_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare x record;
begin
  if not exists (select 1 from booking.reservations c where c.parent_reservation_id = new.id) then return null; end if;
  if new.status is distinct from old.status then
    if new.status = 'cancelled' and old.status in ('pending', 'confirmed') then
      update booking.reservations c set status = 'cancelled', cancelled_at = now(), hold_expires_at = null, cancel_reason = 'ritual_addon_parent_cancelled'
       where c.parent_reservation_id = new.id and c.status in ('pending', 'confirmed') and booking._is_ritual_addon_item(c.order_item_id);
    elsif new.status = 'expired' and old.status = 'pending' then
      update booking.reservations c set status = 'expired'
       where c.parent_reservation_id = new.id and c.status = 'pending' and booking._is_ritual_addon_item(c.order_item_id);
    elsif new.status = 'confirmed' and old.status = 'pending' then
      update booking.reservations c set status = 'confirmed', hold_expires_at = null
       where c.parent_reservation_id = new.id and c.status = 'pending' and booking._is_ritual_addon_item(c.order_item_id);
    end if;
  end if;
  if new.starts_at is distinct from old.starts_at and new.status in ('pending', 'confirmed') then
    for x in select c.id, c.starts_at from booking.reservations c
              where c.parent_reservation_id = new.id and c.status in ('pending', 'confirmed') and booking._is_ritual_addon_item(c.order_item_id) order by c.id loop
      perform booking._ritual_addon_move(x.id, x.starts_at + (new.starts_at - old.starts_at));
    end loop;
  end if;
  return null;
end $function$;


-- ---------------------------------------------------------------------------------------------------------------
-- Korvattavat funktiot (tuotannon määrittely + booking_166-lisäykset)
-- ---------------------------------------------------------------------------------------------------------------

-- booking._attach_addons(bigint,jsonb)
CREATE OR REPLACE FUNCTION booking._attach_addons(p_reservation_id bigint, p_addons jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.reservations; a booking.addons; e jsonb; v_acc jsonb := '{}'::jsonb; v_key text; v_qty integer; v_total numeric := 0;
  v_idtxt text; v_code text; v_lim integer; v_mode text; v_rit jsonb; v_rn integer := 0;
begin
  if p_addons is null or p_addons = 'null'::jsonb then return 0; end if;
  if jsonb_typeof(p_addons) <> 'array' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
  if jsonb_array_length(p_addons) = 0 then return 0; end if;
  if jsonb_array_length(p_addons) > 20 then perform booking._err('invalid_addons', 'Liian monta lisäpalvelua'); end if;
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;

  -- tehokas tila: yleinen vuoro / yksityisvuoro = r.mode (shared / exclusive); resurssivaraus (hoito, saunotus, rituaali; sale_kind 'other') = 'resource';
  -- tapahtuma (kb.products.category = 'event') = 'event' (ei lisäpalveluita)
  select case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end
    into v_mode from booking.product_config pc join kb.products p on p.id = pc.product_id where pc.product_id = r.product_id;
  v_mode := coalesce(v_mode, r.mode);

  -- booking_166: saunarituaali-elementti {"ritual_start": ISO-aika aikavyöhykkeineen, "quantity": henkilöt} käsitellään erikseen
  -- (oma varaus rituaaliresurssille samaan tilaukseen, hinta palvelimella; booking._ritual_addon_attach). Enintään yksi.
  for e in select x from jsonb_array_elements(p_addons) x where jsonb_typeof(x) = 'object' and x ? 'ritual_start' loop
    v_rn := v_rn + 1; v_rit := e;
  end loop;
  if v_rn > 1 then perform booking._err('ritual_addon_invalid', 'Saunarituaalin voi valita vain kerran'); end if;
  if v_rn = 1 then v_total := v_total + booking._ritual_addon_attach(r.id, v_rit); end if;

  for e in select x from jsonb_array_elements(p_addons) x where not (jsonb_typeof(x) = 'object' and x ? 'ritual_start') loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
    v_idtxt := e ->> 'id'; v_code := e ->> 'code';
    if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
    v_qty := (e ->> 'quantity')::int;
    if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
    if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    v_acc := jsonb_set(v_acc, array[a.id::text], to_jsonb(coalesce((v_acc ->> a.id::text)::int, 0) + v_qty));
  end loop;

  for v_key, v_qty in select k, (v_acc ->> k)::int from jsonb_object_keys(v_acc) k order by k::bigint loop
    continue when v_qty = 0;
    select * into a from booking.addons where id = v_key::bigint;
    if not a.active then perform booking._err('addon_inactive', format('Lisäpalvelu "%s" ei ole käytössä', a.name)); end if;
    if not (v_mode = any (a.applies_modes)) then perform booking._err('addon_not_allowed', format('Lisäpalvelu "%s" ei ole saatavilla tälle vuorolle', a.name)); end if;
    v_lim := booking._addon_limit(a.max_per_person, r.persons);
    if v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi valita enintään %s kpl', a.name, v_lim)); end if;
    insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, addon_id, parent_item_id, price_breakdown)
    values (r.order_id, a.name, 'addon', v_qty, a.price_gross, a.price_gross * v_qty, a.vat_rate, a.id, r.order_item_id,
            jsonb_build_object('addon_code', a.code, 'name_en', a.name_en, 'unit_price', a.price_gross, 'quantity', v_qty, 'max_per_person', a.max_per_person));
    v_total := v_total + a.price_gross * v_qty;
  end loop;
  if v_total > 0 then update booking.orders set total_gross = total_gross + v_total where id = r.order_id; end if;
  return v_total;
end $function$;

-- booking._reservation_refund_plan(bigint)
CREATE OR REPLACE FUNCTION booking._reservation_refund_plan(p_reservation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r booking.reservations; o booking.orders; p record; l record;
  v_items bigint[]; v_pending numeric; v_cap numeric; v_net numeric; v_amt numeric; v_left numeric; v_use numeric;
  v_lines jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_unalloc int := 0;
begin
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then return null; end if;
  select * into o from booking.orders where id = r.order_id;
  if r.order_item_id is null or o.external_source is not null then
    return jsonb_build_object('reservation_id', r.id, 'order_id', r.order_id, 'status', r.status, 'total', 0, 'unallocated', 0, 'payments', '[]'::jsonb);
  end if;
  select array_agg(i.id order by i.id) into v_items from booking.order_items i
   where i.order_id = r.order_id and (i.id = r.order_item_id or i.parent_item_id = r.order_item_id
          -- booking_166: vuoron mukana peruuntuva saunarituaali (voimassa oleva lapsivaraus) palautetaan samalla
          or i.id in (select c.order_item_id from booking.reservations c
                       where c.parent_reservation_id = r.id and c.order_id = r.order_id and c.status in ('pending','confirmed')
                         and booking._is_ritual_addon_item(c.order_item_id)));
  for p in select * from booking.payments x where x.order_id = r.order_id and x.status in ('paid','partially_refunded')
             and x.external_source is null order by x.id loop
    if not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id) then v_unalloc := v_unalloc + 1; continue; end if;
    v_pending := coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = p.id and f.status in ('requested','processing')), 0);
    v_cap := p.amount - p.refunded_amount - v_pending;
    select coalesce(sum(c.cap), 0) into v_net from (
      select pl.amount_gross - pl.refunded_gross - coalesce((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) x
              where f.payment_id = p.id and f.status in ('requested','processing') and (x ->> 'payment_line_id')::bigint = pl.id), 0) as cap
        from booking.payment_lines pl where pl.payment_id = p.id and pl.order_item_id = any(v_items)) c;
    v_amt := round(least(v_net, v_cap), 2);
    if v_amt <= 0 then continue; end if;
    v_left := v_amt; v_lines := '[]'::jsonb;
    for l in select pl.id, pl.amount_gross - pl.refunded_gross - coalesce((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) x
                     where f.payment_id = p.id and f.status in ('requested','processing') and (x ->> 'payment_line_id')::bigint = pl.id), 0) as cap
               from booking.payment_lines pl where pl.payment_id = p.id and pl.order_item_id = any(v_items) order by pl.id loop
      exit when v_left <= 0.004;
      continue when l.cap <= 0;
      v_use := least(l.cap, v_left);
      v_lines := v_lines || jsonb_build_object('payment_line_id', l.id, 'amount', v_use);
      v_left := v_left - v_use;
    end loop;
    if v_left > 0.004 then v_amt := v_amt - v_left; end if;
    if v_amt <= 0 then continue; end if;
    v_out := v_out || jsonb_build_object('payment_id', p.id, 'provider', p.provider, 'method', p.method, 'gift_card', p.gift_card_id is not null,
      'online_off', p.provider <> 'manual' and coalesce((select c.mode from booking.integration_config c where c.key = replace(p.provider, '_', '')), 'off') = 'off',
      'amount', v_amt, 'lines', v_lines);
    v_total := v_total + v_amt;
  end loop;
  return jsonb_build_object('reservation_id', r.id, 'order_id', r.order_id, 'status', r.status, 'total', v_total, 'unallocated', v_unalloc, 'payments', v_out);
end $function$;

-- booking.public_get_booking(uuid)
CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode, 'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at,
           'ritual_addon', booking._is_ritual_addon_item(it.id))   -- booking_166: vuoron lisäpalveluna varattu saunarituaali (näytetään vuoron jälkeen)
         order by booking._is_ritual_addon_item(it.id), r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'has_ritual_addon', exists (select 1 from booking.order_items x where x.order_id = o.id and x.kind = 'reservation' and booking._is_ritual_addon_item(x.id)),
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end)
         || booking._checkout_state_json(o.id);
end $function$;

-- booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)
CREATE OR REPLACE FUNCTION booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer, p_addons jsonb DEFAULT NULL::jsonb, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162
begin
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if r.id is null or p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', pr.total));
  v_sub := pr.total;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      -- booking_166: saunarituaali-elementti mukaan esikatseluun samana rivinä kuin varauksessa (tuote + palvelimen hinta)
      if jsonb_typeof(e) = 'object' and e ? 'ritual_start' and coalesce(e ->> 'quantity', '') ~ '^\d{1,3}$' and (e ->> 'quantity')::int > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', -1, 'product_id', (booking._ritual_addon_cfg() ->> 'product_id')::bigint, 'kind', 'reservation',
                     'gross', round(booking._treatment_price((booking._ritual_addon_cfg() ->> 'product_id')::bigint, least((e ->> 'quantity')::int, p_persons)), 2)));
        v_sub := v_sub + round(booking._treatment_price((booking._ritual_addon_cfg() ->> 'product_id')::bigint, least((e ->> 'quantity')::int, p_persons)), 2);
        continue;
      end if;
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;

  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti + yhteystiedot, jotka eivät ole omistajan → sama vastaus kuin tuntemattomalla koodilla
  if v_card.id is not null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
     and not booking._annual_card_owner_ok(v_card, p_email, p_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  if v_card.id is not null or d.is_annual_card_code then
    v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
    if v_err is null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and booking._annual_limit(v_card.customer_id, p_email, p_phone) then v_err := 'annual_card_limit'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    select * into pr from booking._rule_price(p_rule_id, booking._annual_max_persons());
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'persons', booking._annual_max_persons(), 'addons_allowed', false, 'subtotal', pr.total, 'discount', pr.total, 'total', 0,
      'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  -- booking_162: hiljaisen ajan ale ei pinoudu koodin kanssa; koodi voittaa vain jos se on suurempi etu
  v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
  if v_quiet is not null then v_qamt := least(pr.total, round(pr.total * (v_quiet ->> 'percent')::numeric / 100, 2)); end if;
  if v_qamt > 0 and v_qamt >= (v_calc ->> 'discount')::numeric then
    return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
      'discount', v_qamt, 'total', v_sub - v_qamt, 'addons_allowed', true, 'discount_source', 'quiet', 'code_applied', false,
      'code_discount', (v_calc ->> 'discount')::numeric, 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true)
    || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'code_applied', true,
         'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end;
end $function$;

-- booking.reservations_time_window()
CREATE OR REPLACE FUNCTION booking.reservations_time_window()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_class text; w booking.time_window_rules; ls timestamp; le timestamp; v_dt text;
begin
  if new.status not in ('pending', 'confirmed') then return new; end if;
  if new.override_reason is not null then return new; end if;
  if new.external_source is not null and coalesce(booking._jwt_role(), 'service_role') = 'service_role' then return new; end if;
  if tg_op = 'UPDATE' and old.product_id is not distinct from new.product_id and old.starts_at = new.starts_at and old.ends_at = new.ends_at
     and booking._res_active(old.status, old.hold_expires_at) then return new; end if;
  -- booking_166: saunarituaali yleisen vuoron lisäpalveluna (parent_reservation_id = vuoron varaus): alkuaika saa olla mikä tahansa
  -- booking._ritual_addon_starts-listan aika vuoron suhteen (rituaaliluokan allowed_starts ei koske lisäpalvelua). Muut rituaalit ennallaan.
  if new.parent_reservation_id is not null and booking._ritual_addon_start_ok(new.parent_reservation_id, new.product_id, new.starts_at) then return new; end if;
  select pc.time_window_class into v_class from booking.product_config pc where pc.product_id = new.product_id;
  if v_class is null then return new; end if;
  ls := new.starts_at at time zone booking._tz();
  le := new.ends_at at time zone booking._tz();
  v_dt := case when extract(isodow from ls) >= 6 then 'weekend' else 'weekday' end;
  select * into w from booking.time_window_rules where class = v_class and day_type = v_dt;
  if not found then return new; end if;
  if w.allowed_starts is not null and not (date_trunc('minute', ls)::time = any (w.allowed_starts)) then
    perform booking._err('ritual_start', 'Rituaalin alkuaika voi olla vain ' || (select string_agg(to_char(t, 'HH24:MI'), ', ' order by t) from unnest(w.allowed_starts) t));
  end if;
  if w.earliest_start is not null and ls::time < w.earliest_start
     or w.latest_end is not null and (le::time > w.latest_end or le::date <> ls::date) then
    perform booking._err('time_window', 'Hoitojen ja saunotusten aika: ' || case v_dt when 'weekday' then 'ma–pe' else 'la–su' end || ' alkaa aikaisintaan '
                         || to_char(w.earliest_start, 'HH24:MI') || ' ja päättyy viimeistään ' || to_char(w.latest_end, 'HH24:MI'));
  end if;
  return new;
end $function$;


drop trigger if exists reservations_ritual_addon_parent on booking.reservations;
create trigger reservations_ritual_addon_parent after update of status, starts_at on booking.reservations
  for each row when (old.status is distinct from new.status or old.starts_at is distinct from new.starts_at)
  execute function booking._ritual_addon_parent_trg();

do $p$
declare f text;
begin
  foreach f in array array['booking._ritual_addon_cfg()', 'booking._ritual_addon_starts(timestamptz,timestamptz)', 'booking._is_ritual_addon_item(bigint)',
                           'booking._ritual_addon_session_ok(bigint)', 'booking._ritual_addon_fit(timestamptz,integer,boolean)',
                           'booking._ritual_addon_start_ok(bigint,bigint,timestamptz)', 'booking._ritual_addon_attach(bigint,jsonb)',
                           'booking._ritual_addon_move(bigint,timestamptz)', 'booking._ritual_addon_parent_trg()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  revoke all on function booking.public_ritual_addon(bigint, date, integer) from public;
  grant execute on function booking.public_ritual_addon(bigint, date, integer) to anon, authenticated, service_role;
end $p$;

-- Uudelleenajo booking_171:n jälkeen: palautetaan booking_171:n public_preview_code (md5 e8fe514b…) täsmälleen, jottei hiljaisen ajan korjaus kumoudu.
do $k$
declare d text := nullif(current_setting('booking.m166_keep_preview', true), '');
begin
  if d is not null then
    execute d;
    if md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure)) <> 'e8fe514b4ec9db4043d388e5547f94ad' then
      raise exception 'booking_166: booking_171:n public_preview_code ei palautunut';
    end if;
    perform set_config('booking.m166_keep_preview', '', true);
  end if;
end $k$;
