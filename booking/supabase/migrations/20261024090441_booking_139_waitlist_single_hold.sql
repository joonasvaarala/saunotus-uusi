-- booking_139: jonotuslistan pito vain yhdelle kerrallaan per vuoro (omistajan päätös). Korjaa booking_137:n, joka antoi
-- yli 48 h ennen vuoroa pidon jokaiselle mahtuvalle jonottajalle (esim. jonossa A5, B1, C4, D3, vapautuu 4 → B ja D pidossa).
-- Sääntö:
-- 1. Vuoroon < waitlist_hold_min_hours_before (48) h: ennallaan. Ei pitoa, paikka myynnissä, ilmoitus kaikille mahtuville.
-- 2. Vuoroon ≥ 48 h: vuoroa (rule_id + session_date) kohden vain YKSI voimassa oleva pito kerrallaan. Se menee jonon
--    järjestyksessä (created_at, id) ensimmäiselle mahtuvalle, jolla ei ole vielä ollut pitoa tähän vuoroon. Pito kestää
--    waitlist_offer_minutes (120) min. Pidon aikana muut jonottajat eivät saa tästä vuorosta mitään.
-- 3. Pito vanhenee → uutta pitoa ei anneta. Seuraava ajo (uusi ajastettu booking.waitlist_sweep() minuutin välein tai
--    seuraava vapautumistriggeri) ilmoittaa kaikille mahtuville ilman pitoa kuten alle 48 h:n tilassa. Vanhentuneen pidon
--    haltijan lunastus ei enää palauta offer_expired-virhettä, vaan toimii kuten ilman pitoa (ok + enough mahtuvuuden mukaan,
--    lisäksi hold_expired=true), joten hän voi varata tavallisena asiakkaana.
-- 4. Uusi vapautuminen: vuoron vapaa kapasiteetti (booking._sessions.remaining) on suurempi kuin edellisen ajon jälkeen
--    tallennettu booking.waitlist_session_state.offered_free. Jokainen ajo tallentaa offered_free = nykyinen remaining; kun pito
--    on voimassa, tallennetaan vain lasku (least), jolloin pidon aikana vapautuneet paikat jäävät uudeksi vapautumiseksi, joka
--    käsitellään pidon päätyttyä (taas yksi pito seuraavalle, jolla ei ole ollut pitoa). Pitojen kasautumista ei synny, koska
--    voimassa olevan pidon aikana ei anneta uutta pitoa eikä muita ilmoituksia. Jos uudessa vapautumisessa ei ole yhtään
--    mahtuvaa, jolla ei ole ollut pitoa, ilmoitetaan kaikille mahtuville ilman pitoa.
-- 5. Ei tuplailmoituksia: ilmoitus vain tilasta 'waiting' (booking_135/#126 ennallaan), dedupe-avain ennallaan.
-- Tietomalli: booking.waitlist_entries.hold_expires_at (pidon päättymisaika; null = ei pitoa koskaan; säilyy historiana,
-- vaikka jonovaraus palaisi tilaan 'waiting') ja booking.waitlist_session_state (rule_id, session_date, offered_free).
-- Rinnakkaisuus: vuorokohtainen pg_try_advisory_xact_lock; jos toinen transaktio käsittelee vuoroa, ajo ohittaa sen ja
-- waitlist_sweep hoitaa sen seuraavalla minuutilla (vapaan kapasiteetin kasvu näkyy yhä offered_freen ylityksenä).
-- Käyttöönotto: nykyiset booking_137-pidot siirretään hold_expires_at-sarakkeeseen ja tulevien jonotettujen vuorojen
-- offered_free alustetaan nykyiseen vapaaseen kapasiteettiin (ei näennäistä uutta vapautumista ensimmäisessä sweepissä).
-- 6. Pidon aikana paikka EI ole julkisessa myynnissä (omistajan lisävaatimus): booking._pool_peak laskee voimassa olevan pidon
--    (status notified, hold_expires_at > now()) henkilömäärän vuoron kapasiteettipooleihin. Koska kaikki poolisaatavuus kulkee
--    _pool_peakin kautta, pito näkyy samoin julkisessa haussa (public_availability, public_availability_all eli booking_133:n
--    nopeutettu polku, _sessions), ajanmuutoksessa, jonotuslistan tarkistuksissa ja varauksen luonnin kapasiteettitarkistuksessa
--    (_check_claim reservations_validate-triggerissä, sama booking:space-advisory-lukko kuin muilla varauksilla).
--    Poikkeukset (booking._waitlist_hold_counts): pidon haltija itse (public_waitlist_claim ja public_create_booking samalla
--    sähköpostilla: transaktiokohtainen booking.waitlist_hold_exempt = pidon id), jonotuslistan oma laskenta ('all', vähentää pidot
--    itse) sekä henkilökunta ja service_role (hallinta voi ohittaa pidon; admin_day_view.waitlist_holds näyttää pidot).
--    Pito päättyy now()-ehdolla (vanheneminen), varauksella (booking_132:n konversiotriggeri → booked) tai jonosta poistumisella
--    (cancelled), jolloin paikat palaavat myyntiin heti. Pitoa ei anneta, jos vuoron tilan lukko (booking:space) on varattu
--    (pg_try_advisory_xact_lock), joten pito ja rinnakkainen varaus eivät voi ottaa samoja paikkoja.
-- Ei public-skeemaa. Uudelleenajettava. Sähköpostit ja edge-funktiot ennallaan (viesti ei lupaa pitoa).
-- Rollback: booking/supabase/rollbacks/20261024090441_booking_139_ROLLBACK.sql (booking_137-tila).
set local lock_timeout = '5s';

alter table booking.waitlist_entries add column if not exists hold_expires_at timestamptz;
comment on column booking.waitlist_entries.hold_expires_at is
  'booking_139: jonotuspidon päättymisaika (vain vuoroon ≥ waitlist_hold_min_hours_before h). Null = jonovaraukselle ei ole annettu pitoa tähän vuoroon.';

create table if not exists booking.waitlist_session_state (
  rule_id bigint not null references booking.schedule_rules(id) on delete cascade,
  session_date date not null,
  offered_free integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (rule_id, session_date)
);
comment on table booking.waitlist_session_state is
  'booking_139: vuoron vapaa kapasiteetti edellisen jonotusajon jälkeen (offered_free). Kasvu = uusi vapautuminen → yksi uusi pito (vuoroon ≥ 48 h).';
alter table booking.waitlist_session_state enable row level security;
revoke all on booking.waitlist_session_state from public, anon, authenticated;
grant all on booking.waitlist_session_state to service_role;

-- Nykyiset booking_137-pidot (laskettu notified_at:sta) talteen sarakkeeseen; vanhat pidot vanhenevat normaalisti.
update booking.waitlist_entries
   set hold_expires_at = booking._waitlist_offer_expires_at(coalesce(notified_at,updated_at),starts_at)
 where status = 'notified' and hold_expires_at is null
   and booking._waitlist_offer_expires_at(coalesce(notified_at,updated_at),starts_at) is not null;

-- Yhden jonovarauksen ilmoitus (sähköposti + WhatsApp-ajastus), booking_137:n silmukan runko sellaisenaan.
-- p_hold_expires_at: pidon päättymisaika tai null (ilmoitus ilman pitoa).
create or replace function booking._waitlist_notify_entry(p_id bigint, p_hold_expires_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  w booking.waitlist_entries;
  v_site text := rtrim(coalesce(booking._setting('site_base_url') #>> '{}',''),'/');
  v_shop text;
  v_name text;
  v_dedupe text;
  v_wa boolean := booking._setting('waitlist_whatsapp_enabled','false'::jsonb) = 'true'::jsonb;
  v_h integer := extract(hour from now() at time zone 'Europe/Helsinki')::int;
  v_start integer := (booking._setting('waitlist_quiet_hours_start','21'::jsonb) #>> '{}')::int;
  v_end integer := (booking._setting('waitlist_quiet_hours_end','8'::jsonb) #>> '{}')::int;
  v_wa_after timestamptz;
begin
  select * into w from booking.waitlist_entries where id = p_id and status = 'waiting';
  if not found then return; end if;
  -- Kaupan polku kielen mukaan (content/site.json pages.book): fi /varaa/, en /en/book/.
  v_shop := case when w.locale='en' then '/en/book/' else '/varaa/' end;
  select coalesce(case when w.locale='en' then nullif(p.name_en,'') end,p.name)
    into v_name from kb.products p where p.id=w.product_id;
  v_dedupe := 'waitlist:'||w.id||':spot_freed:'||to_char(w.updated_at,'YYYYMMDDHH24MISSUS');
  -- Jonotuslistan sähköposti kuuluu nykyiseen send-emails -putkeen; dedupe estää kaksoislähetyksen.
  insert into booking.email_outbox(kind,locale,dedupe_key,status,payload)
  values ('waitlist_spot_freed',w.locale,v_dedupe,'pending',jsonb_build_object(
    'to_email',w.customer_email,'to_name',w.customer_name,'product_name',v_name,
    'starts_at',w.starts_at,'ends_at',w.ends_at,'persons',w.persons,
    'book_url',v_site||v_shop||'#/varaa/'||w.rule_id||'/'||w.session_date||'/'||w.product_id||'?n='||w.persons||'&wl='||w.public_token,
    'leave_url',v_site||v_shop||'?poistu_jonosta='||w.public_token))
  on conflict (dedupe_key) do nothing;
  v_wa_after := null;
  if v_wa and w.whatsapp_opt_in and w.customer_phone is not null then
    if v_start > v_end then
      if v_h >= v_start then
        v_wa_after := (((now() at time zone 'Europe/Helsinki')::date + 1)::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
      elsif v_h < v_end then
        v_wa_after := ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
      else v_wa_after := now(); end if;
    else
      v_wa_after := case when v_h >= v_start and v_h < v_end then
        ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki'
        else now() end;
    end if;
  end if;
  -- hold_expires_at kirjoitetaan vain pidolle; aiempi pito säilyy historiana (ei toista pitoa samaan vuoroon).
  update booking.waitlist_entries set status='notified',notified_at=now(),
    hold_expires_at=coalesce(p_hold_expires_at,hold_expires_at),
    whatsapp_send_after=v_wa_after,whatsapp_queued_at=null,updated_at=now()
  where id=w.id;
end $$;

-- Yhden vuoron (rule_id + session_date) käsittely, ks. säännöt yllä. Palauttaa ilmoitusten määrän.
create or replace function booking._waitlist_process_session(p_rule_id bigint, p_date date)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  w booking.waitlist_entries;
  v_s record;
  v_product bigint;
  v_space bigint;
  v_prev text;
  v_cur integer;
  v_offered integer;
  v_hold_until timestamptz;
  v_active boolean;
  v_mode text;
  v_held integer;
  v_n integer := 0;
begin
  if p_rule_id is null or p_date is null then return 0; end if;
  -- Sama vuoro yksi transaktio kerrallaan (ei kahta rinnakkaista pitoa). Varattu → ohitetaan, sweep hoitaa myöhemmin.
  if not pg_try_advisory_xact_lock(hashtextextended('booking:waitlist:'||p_rule_id||':'||p_date, 0)) then return 0; end if;
  select r.product_id, r.space_id into v_product, v_space from booking.schedule_rules r where r.id = p_rule_id;
  if not found then return 0; end if;
  -- Sama tilan lukko kuin varauksen kapasiteettitarkistuksella: pito ei kilpaile rinnakkaisen varauksen kanssa. Varattu → ohitetaan.
  if not pg_try_advisory_xact_lock(hashtextextended('booking:space:' || v_space::text, 0)) then return 0; end if;
  -- Raaka vapaa kapasiteetti ilman pitoja (pidot vähennetään alla itse).
  v_prev := current_setting('booking.waitlist_hold_exempt', true);
  perform set_config('booking.waitlist_hold_exempt', 'all', true);
  select * into v_s from booking._sessions(p_date,p_date,v_product,true) s
    where s.rule_id=p_rule_id and s.session_date=p_date limit 1;
  perform set_config('booking.waitlist_hold_exempt', coalesce(v_prev, ''), true);
  if not found or v_s.starts_at <= now() then return 0; end if;
  v_cur := case when v_s.status = 'available' then greatest(coalesce(v_s.remaining,0),0) else 0 end;
  select st.offered_free into v_offered from booking.waitlist_session_state st
   where st.rule_id=p_rule_id and st.session_date=p_date;
  v_offered := coalesce(v_offered, 0);
  -- Pitotila: ilmoitus nyt antaisi pidon (vuoroon ≥ waitlist_hold_min_hours_before h).
  v_hold_until := booking._waitlist_offer_expires_at(now(), v_s.starts_at);
  v_active := exists (select 1 from booking.waitlist_entries a
    where a.rule_id=p_rule_id and a.session_date=p_date and a.status='notified' and a.hold_expires_at > now());
  if v_hold_until is not null and v_active then
    -- Yksi pito kerrallaan: muut eivät saa mitään. Vain lasku kirjataan; kasvu jää uudeksi vapautumiseksi pidon jälkeen.
    insert into booking.waitlist_session_state(rule_id,session_date,offered_free,updated_at)
    values (p_rule_id,p_date,v_cur,now())
    on conflict (rule_id,session_date) do update
      set offered_free = least(booking.waitlist_session_state.offered_free, excluded.offered_free), updated_at = now();
    return 0;
  end if;
  v_mode := case when v_hold_until is not null and v_cur > v_offered then 'hold' else 'all' end;
  for w in select * from booking.waitlist_entries
    where rule_id=p_rule_id and session_date=p_date and status='waiting' and starts_at>now()
      and (v_mode = 'all' or hold_expires_at is null)
    order by created_at,id for update skip locked
  loop
    if v_s.starts_at<>w.starts_at or v_s.status<>'available' then continue; end if;
    -- booking_134/135: jonon järjestys, mahtuvuus ratkaisee. Vähennetään voimassa olevat pidot samasta vuorosta ja
    -- päällekkäisistä, kapasiteettipoolin jakavista vuoroista (booking_139: vain hold_expires_at > now()).
    select coalesce(sum(o.persons),0)::int into v_held
      from booking.waitlist_entries o
     where o.status='notified' and o.id<>w.id and o.starts_at>now() and o.hold_expires_at > now()
       and o.starts_at<w.ends_at and o.ends_at>w.starts_at
       and ((o.rule_id=w.rule_id and o.session_date=w.session_date)
         or exists (select 1 from booking.schedule_rule_pools a
                      join booking.schedule_rule_pools b on b.pool_id=a.pool_id
                     where a.rule_id=o.rule_id and b.rule_id=w.rule_id));
    if v_cur - v_held < w.persons then continue; end if;
    if v_mode = 'hold' then
      perform booking._waitlist_notify_entry(w.id, v_hold_until);
      v_n := 1;
      exit;   -- vain yksi pito
    end if;
    perform booking._waitlist_notify_entry(w.id, null);
    v_n := v_n + 1;
  end loop;
  if v_mode = 'hold' and v_n = 0 then
    -- Uusi vapautuminen, mutta kukaan mahtuva ilman aiempaa pitoa ei ole jonossa → ilmoitus kaikille mahtuville ilman pitoa.
    for w in select * from booking.waitlist_entries
      where rule_id=p_rule_id and session_date=p_date and status='waiting' and starts_at>now()
      order by created_at,id for update skip locked
    loop
      if v_s.starts_at<>w.starts_at or v_s.status<>'available' then continue; end if;
      select coalesce(sum(o.persons),0)::int into v_held
        from booking.waitlist_entries o
       where o.status='notified' and o.id<>w.id and o.starts_at>now() and o.hold_expires_at > now()
         and o.starts_at<w.ends_at and o.ends_at>w.starts_at
         and ((o.rule_id=w.rule_id and o.session_date=w.session_date)
           or exists (select 1 from booking.schedule_rule_pools a
                        join booking.schedule_rule_pools b on b.pool_id=a.pool_id
                       where a.rule_id=o.rule_id and b.rule_id=w.rule_id));
      if v_cur - v_held < w.persons then continue; end if;
      perform booking._waitlist_notify_entry(w.id, null);
      v_n := v_n + 1;
    end loop;
  end if;
  insert into booking.waitlist_session_state(rule_id,session_date,offered_free,updated_at)
  values (p_rule_id,p_date,v_cur,now())
  on conflict (rule_id,session_date) do update set offered_free = excluded.offered_free, updated_at = now();
  return v_n;
end $$;

-- Vapautumistriggerin (booking_132) kutsuma: käsittelee ikkunan jokaisen jonotetun vuoron jonon järjestyksessä.
create or replace function booking._notify_waitlist_for_window(p_space_id bigint,p_starts_at timestamptz,p_ends_at timestamptz)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  k record;
  v_n integer := 0;
begin
  if booking._setting('waitlist_enabled','true'::jsonb) <> 'true'::jsonb then return 0; end if;
  if p_space_id is null or p_starts_at is null or p_ends_at is null then return 0; end if;
  for k in select e.rule_id, e.session_date from booking.waitlist_entries e
    where e.space_id=p_space_id and e.status in ('waiting','notified') and e.starts_at>now()
      and e.starts_at<p_ends_at and e.ends_at>p_starts_at
    group by e.rule_id, e.session_date
    order by min(e.created_at), min(e.id)
  loop
    v_n := v_n + booking._waitlist_process_session(k.rule_id, k.session_date);
  end loop;
  return v_n;
end $$;

-- Ajastettu ajo (pg_cron, minuutin välein): vanhentuneen pidon jälkeinen ilmoitus kaikille mahtuville (sääntö 3),
-- ohitettujen rinnakkaisajojen ja muiden kuin varaustriggerin havaitsemien kapasiteettimuutosten käsittely sekä
-- offered_freen päivitys. Vanhat tilarivit siivotaan.
create or replace function booking.waitlist_sweep()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  k record;
  v_n integer := 0;
begin
  delete from booking.waitlist_session_state where session_date < current_date - 2;
  if booking._setting('waitlist_enabled','true'::jsonb) <> 'true'::jsonb then return 0; end if;
  for k in select e.rule_id, e.session_date from booking.waitlist_entries e
    where e.status in ('waiting','notified') and e.starts_at>now()
    group by e.rule_id, e.session_date
    order by min(e.created_at), min(e.id)
  loop
    v_n := v_n + booking._waitlist_process_session(k.rule_id, k.session_date);
  end loop;
  return v_n;
end $$;

-- booking_139 (pito pois julkisesta myynnistä): lasketaanko jonotuspito (waitlist_entries.id) kapasiteetista tässä kutsussa?
-- Ei, kun transaktiokohtainen booking.waitlist_hold_exempt = 'all' (jonotuslistan oma laskenta, joka vähentää pidot itse) tai
-- = pidon id (haltijan lunastus ja varaus), eikä henkilökunnalle (is_staff) tai service_rolelle (Johku-synkka, maksukuittaukset):
-- henkilökunta voi ohittaa pidon, ja hallinnan päivänäkymä näyttää pidot erikseen (admin_day_view.waitlist_holds).
create or replace function booking._waitlist_hold_counts(p_id bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select case coalesce(current_setting('booking.waitlist_hold_exempt', true), '')
           when 'all' then false
           when p_id::text then false
           else not (coalesce(booking._jwt_role(), '') = 'service_role' or booking.is_staff()) end
$$;
revoke all on function booking._waitlist_hold_counts(bigint) from public,anon,authenticated;

create index if not exists waitlist_entries_active_hold_idx on booking.waitlist_entries (starts_at)
  where status = 'notified' and hold_expires_at is not null;

-- Kaikki pooli-saatavuus kulkee _pool_peakin kautta: _pools_remaining → _sessions (public_availability, public_availability_all,
-- päivänäkymät, ajanmuutos, jonotuslistan tarkistukset) ja _check_claim (reservations_validate / reservation_legs_validate:
-- julkinen ja hallinnan varauksen luonti, muutos, lisäys tilaukseen, hoitovaraukset). Lukitus ennallaan (booking:space).
-- Suorituskyky: SQL-kielinen security definer -funktio suunnitellaan joka kutsulla uudelleen; pitohaara kasvatti suunnittelua
-- (kk-saatavuus ~50 → ~69 ms paikallisesti). Sama kysely plpgsql-kääreessä käyttää istunnon välimuistiin tallennettua suunnitelmaa
-- (~6 ms). Kysely ja tulos ovat samat; rollback palauttaa booking_138:n SQL-version.
CREATE OR REPLACE FUNCTION booking._pool_peak(p_pool bigint, p_from timestamp with time zone, p_to timestamp with time zone, p_exclude bigint DEFAULT NULL::bigint)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return (
with rs as materialized (
    select r.starts_at + make_interval(mins => r.claim_offset_min) as s,
           case when r.claim_minutes is null then r.ends_at
                else r.starts_at + make_interval(mins => r.claim_offset_min + r.claim_minutes) end as e,
           r.persons as n
      from booking.reservations r
     where r.mode = 'shared' and r.pool_ids @> array[p_pool]
       and r.status in ('pending', 'confirmed')
       and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at + make_interval(mins => r.claim_offset_min) < p_to
       and case when r.claim_minutes is null then r.ends_at
                else r.starts_at + make_interval(mins => r.claim_offset_min + r.claim_minutes) end > p_from
       and r.id is distinct from p_exclude
    union all
    select l.starts_at as s, l.ends_at as e, l.persons as n
      from booking.reservation_legs l
      join booking.reservations r on r.id = l.reservation_id
     where l.mode = 'shared' and l.pool_ids @> array[p_pool]
       and r.status in ('pending', 'confirmed')
       and booking._res_active(r.status, r.hold_expires_at)
       and l.starts_at < p_to and l.ends_at > p_from
       -- indeksiehto (gist during): least/greatest + '[]' = aina ylijoukko yllä olevasta vertailusta, ei virhettä käänteisillä rajoilla
       and l.during && tstzrange(least(p_from, p_to), greatest(p_from, p_to), '[]')
       and l.reservation_id is distinct from p_exclude
    union all
    -- booking_139: voimassa oleva jonotuspito (vain vuoroon ≥ 48 h annettu, hold_expires_at > now()) varaa pidon henkilömäärän
    -- vuoron ajaksi vuoron kapasiteettipooleista. Ei koske pidon haltijaa itseään eikä henkilökuntaa (_waitlist_hold_counts).
    select w.starts_at as s, w.ends_at as e, w.persons as n
      from booking.waitlist_entries w
      join booking.schedule_rules sr on sr.id = w.rule_id and sr.mode = 'shared'
     where w.status = 'notified' and w.hold_expires_at > now()
       and w.starts_at < p_to and w.ends_at > p_from
       and exists (select 1 from booking.schedule_rule_pools rp where rp.rule_id = w.rule_id and rp.pool_id = p_pool)
       and booking._waitlist_hold_counts(w.id)
  ), base as (
    select coalesce(sum(n), 0) as n from rs where s <= p_from
  ), ev as (
    select e as t, -n as d from rs where e > p_from and e < p_to
    union all
    select s as t, n as d from rs where s > p_from and s < p_to
  ), step as (
    select t, sum(d) as d from ev group by t
  ), run as (
    select (select n from base) + sum(d) over (order by t) as load from step
  )
  select coalesce(greatest((select n from base), (select max(load) from run)), 0)::integer
  );
end
$function$;

CREATE OR REPLACE FUNCTION booking.public_create_booking(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip();
  v_cust bigint; v_res jsonb; v_status text; v_pay_method text; v_pay_provider text;
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_detail text; v_msg text;
  v_hold int; v_invoice boolean; v_hold_mode boolean; v_group boolean; v_thr int := booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000);
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;

  -- rate limit (kirjataan myös estetyt yritykset)
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;

  -- syötteiden validointi
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  -- rajoita samanaikaisia maksamattomia pitoja / sähköposti
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;

  -- booking_53: pitotila (public_payment_mode <> 'pay_later'): varaus odottaa maksua; yritysasiakas laskulle jos checkout_company_invoice_enabled
  v_invoice := v_is_company and coalesce((booking._setting('checkout_company_invoice_enabled', 'true'::jsonb) #>> '{}')::boolean, true);
  v_hold_mode := v_mode <> 'pay_later' and not v_invoice;
  v_group := v_hold_mode and v_thr > 0 and p_persons >= v_thr;
  if v_hold_mode and not v_group and not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – varausta ei voi tehdä juuri nyt');
  end if;
  v_status := case when v_hold_mode then 'pending' else 'confirmed' end;
  v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
  v_pay_provider := 'manual';
  v_hold := case when v_group then booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60) * 1440 else booking._checkout_hold_minutes() end;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    -- booking_139: jonotuspidon haltija (sama sähköposti, voimassa oleva pito tähän vuoroon) ei kilpaile omaa pitoaan vastaan.
    -- Transaktiokohtainen asetus; virhe kumoaa sen alitransaktion mukana, onnistuneen luonnin jälkeen se nollataan alla.
    perform set_config('booking.waitlist_hold_exempt', coalesce((select w.id::text from booking.waitlist_entries w
      where w.rule_id = p_rule_id and w.session_date = p_date and lower(w.customer_email) = v_email
        and w.status = 'notified' and w.hold_expires_at > now() order by w.id limit 1), ''), true);
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale,
                                                 (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                         (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note,
                                          v_status, v_hold, true);
    perform booking._stamp_order_billing((v_res ->> 'order_id')::bigint, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
    v_total := (v_res ->> 'total')::numeric + v_add;
    if not v_hold_mode then   -- pitotilassa ei luoda paikkaajamaksua: maksu syntyy vasta kun asiakas maksaa (MobilePay / lahjakortti)
      insert into booking.payments(order_id, method, provider, status, amount)
      values ((v_res ->> 'order_id')::bigint, v_pay_method, v_pay_provider, 'pending', v_total);
    end if;
    update booking.orders set payment_status = 'unpaid', hold_kind = case when v_hold_mode then (case when v_group then 'preliminary' else 'checkout' end) end
     where id = (v_res ->> 'order_id')::bigint;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform set_config('booking.waitlist_hold_exempt', '', true);

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
                            'status', v_status, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'total', v_total, 'addons_total', v_add, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', v_kind)
         || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_day_view(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
        v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
        v_prep jsonb; v_totals jsonb;
begin
  perform booking._require_staff();
  with rs as (
    select r.rule_id, r.starts_at, r.ends_at, r.order_item_id, coalesce(it.product_name, '') as product_name
      from booking.reservations r left join booking.order_items it on it.id = r.order_item_id
     where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)),
  per as (
    select rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id, min(ad.code) as code, min(ai.product_name) as name, sum(ai.quantity)::int as qty
      from rs join booking.order_items ai on ai.parent_item_id = rs.order_item_id and ai.kind = 'addon'
      left join booking.addons ad on ad.id = ai.addon_id
     group by rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id),
  grp as (
    select rule_id, starts_at, ends_at, product_name,
           jsonb_agg(jsonb_build_object('addon_id', addon_id, 'code', code, 'name', name, 'quantity', qty) order by name) as items
      from per group by rule_id, starts_at, ends_at, product_name)
  select (select coalesce(jsonb_agg(jsonb_build_object('rule_id', g.rule_id, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
                    'product_name', g.product_name, 'items', g.items) order by g.starts_at, g.rule_id), '[]'::jsonb) from grp g),
         (select coalesce(jsonb_agg(jsonb_build_object('addon_id', t.addon_id, 'code', t.code, 'name', t.name, 'quantity', t.qty) order by t.name), '[]'::jsonb)
            from (select addon_id, min(code) as code, min(name) as name, sum(qty)::int as qty from per group by addon_id) t)
    into v_prep, v_totals;
  return jsonb_build_object(
    'date', p_date,
    'sessions', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.rule_id)
                           from booking._sessions(p_date, p_date, null, false) s), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at,
        'source', coalesce(r.external_source, 'native'), 'external_id', r.external_id,
        'customer_kind', o.customer_kind, 'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
        'space_code', sp.code, 'lifecycle', pcf.lifecycle, 'quota_exempt', r.quota_exempt, 'override_reason', r.override_reason,
        'therapist_missing', r.therapist_missing, 'therapist_exception_at', r.therapist_exception_at, 'therapist_exception_note', r.therapist_exception_note,
        'therapist_missing_open', (r.therapist_missing and r.therapist_exception_at is null and not exists (select 1 from booking.reservation_legs tl where tl.reservation_id = r.id and tl.role = 'therapist')),
        'claim_offset_min', r.claim_offset_min, 'claim_minutes', r.claim_minutes, 'parent_reservation_id', r.parent_reservation_id,
        'option', booking._option_json(r.product_option_id),
        'option_missing', (r.product_option_id is null and exists (select 1 from booking.product_options x where x.product_id = r.product_id and x.active)),
        'legs', coalesce((select jsonb_agg(jsonb_build_object('leg_id', l.id, 'role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
                                  'persons', l.persons, 'skill', l.skill) order by l.starts_at, l.id)
                            from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'code', (select a2.code from booking.addons a2 where a2.id = ai.addon_id), 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id join booking.resources sp on sp.id = r.space_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.product_config pcf on pcf.product_id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'prep', v_prep, 'addon_totals', v_totals,
    -- booking_139: voimassa olevat jonotuspidot (henkilökunta voi ohittaa pidon, näkymä kertoo siitä).
    'waitlist_holds', coalesce((select jsonb_agg(jsonb_build_object('rule_id', w.rule_id, 'starts_at', w.starts_at, 'persons', w.persons,
        'hold_expires_at', w.hold_expires_at) order by w.starts_at, w.id)
        from booking.waitlist_entries w where w.status = 'notified' and w.hold_expires_at > now()
         and w.starts_at < v_to and w.ends_at > v_from), '[]'::jsonb),
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'resource_code', br.code, 'closure_event_id', b.closure_event_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b join booking.resources br on br.id = b.space_id where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $function$;

-- booking_139: vanhentunut pito ei estä varausta: lunastus toimii kuten ilman pitoa (mahtuvuus ratkaisee) ja kertoo
-- hold_expired=true. offer_expired-koodia ei enää palauteta (kauppa tukee sitä yhä rollbackin varalta).
create or replace function booking.public_waitlist_claim(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  w booking.waitlist_entries;
  v_s record;
  v_enough boolean;
  v_ip text := booking._client_ip();
  v_hold_expired boolean;
begin
  if p_token is null then return jsonb_build_object('ok',false,'code','not_found'); end if;
  select * into w from booking.waitlist_entries where public_token = p_token and status in ('waiting','notified') for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found'); end if;
  if not booking._rate_limit('waitlist:claim:' || p_token::text, 30, interval '10 minutes')
     or (v_ip is not null and not booking._rate_limit('waitlist:claim:ip:' || v_ip, 60, interval '10 minutes')) then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if w.starts_at <= now() then return jsonb_build_object('ok',false,'code','expired'); end if;
  v_hold_expired := w.status = 'notified' and w.hold_expires_at is not null and w.hold_expires_at <= now();
  -- Oma voimassa oleva pito ei vähennä haltijan saatavuutta; muiden pidot vähentävät.
  perform set_config('booking.waitlist_hold_exempt', w.id::text, true);
  select * into v_s from booking._sessions(w.session_date,w.session_date,w.product_id,true) s
    where s.rule_id = w.rule_id and s.session_date = w.session_date limit 1;
  perform set_config('booking.waitlist_hold_exempt', '', true);
  v_enough := found and v_s.starts_at = w.starts_at and v_s.status = 'available' and v_s.remaining >= w.persons;
  if not v_enough and w.status = 'notified' then
    -- clock_timestamp: uusi updated_at → uusi dedupe-avain seuraavalle ilmoitukselle.
    update booking.waitlist_entries set status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,
      updated_at=clock_timestamp() where id = w.id;
  end if;
  return jsonb_build_object('ok',true,'rule_id',w.rule_id,'product_id',w.product_id,'session_date',w.session_date,
    'persons',w.persons,'enough',v_enough,'hold_expired',v_hold_expired,
    'remaining',case when v_enough then v_s.remaining end);
end $$;

revoke all on function booking.public_waitlist_claim(uuid) from public;
grant execute on function booking.public_waitlist_claim(uuid) to anon,authenticated,service_role;
revoke all on function booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function booking._waitlist_notify_entry(bigint,timestamptz) from public,anon,authenticated;
revoke all on function booking._waitlist_process_session(bigint,date) from public,anon,authenticated;
revoke all on function booking.waitlist_sweep() from public,anon,authenticated;
grant execute on function booking.waitlist_sweep() to service_role;

-- Käyttöönotto: tulevien jonotettujen vuorojen nykyinen vapaa kapasiteetti = jo käsitelty (ei näennäistä uutta vapautumista).
select set_config('booking.waitlist_hold_exempt', 'all', true);   -- raaka vapaa kapasiteetti (kuten _waitlist_process_session)
insert into booking.waitlist_session_state(rule_id,session_date,offered_free)
select k.rule_id, k.session_date,
       coalesce((select case when s.status='available' then greatest(s.remaining,0) else 0 end
                   from booking._sessions(k.session_date,k.session_date,r.product_id,true) s
                  where s.rule_id=k.rule_id and s.session_date=k.session_date limit 1),0)
  from (select distinct e.rule_id, e.session_date from booking.waitlist_entries e
         where e.status in ('waiting','notified') and e.starts_at>now()) k
  join booking.schedule_rules r on r.id=k.rule_id
on conflict (rule_id,session_date) do nothing;
select set_config('booking.waitlist_hold_exempt', '', true);

do $$ begin
  if to_regprocedure('cron.schedule(text,text,text)') is not null
     and not exists (select 1 from cron.job where jobname = 'booking_waitlist_sweep') then
    perform cron.schedule('booking_waitlist_sweep', '* * * * *', 'select booking.waitlist_sweep()');
  end if;
exception when others then
  raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
