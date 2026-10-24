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
-- Ei public-skeemaa. Uudelleenajettava. Sähköpostit ja edge-funktiot ennallaan (viesti ei lupaa pitoa).
-- Rollback: booking/supabase/rollbacks/20261024115000_booking_139_ROLLBACK.sql (booking_137-tila).
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
  select r.product_id into v_product from booking.schedule_rules r where r.id = p_rule_id;
  if not found then return 0; end if;
  select * into v_s from booking._sessions(p_date,p_date,v_product,true) s
    where s.rule_id=p_rule_id and s.session_date=p_date limit 1;
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
  select * into v_s from booking._sessions(w.session_date,w.session_date,w.product_id,true) s
    where s.rule_id = w.rule_id and s.session_date = w.session_date limit 1;
  v_enough := found and v_s.starts_at = w.starts_at and v_s.status = 'available' and v_s.remaining >= w.persons;
  if not v_enough and w.status = 'notified' then
    -- clock_timestamp: uusi updated_at → uusi dedupe-avain seuraavalle ilmoitukselle.
    update booking.waitlist_entries set status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,
      updated_at=clock_timestamp() where id = w.id;
  end if;
  return jsonb_build_object('ok',true,'rule_id',w.rule_id,'product_id',w.product_id,'session_date',w.session_date,
    'persons',w.persons,'enough',v_enough,'hold_expired',v_hold_expired);
end $$;

revoke all on function booking.public_waitlist_claim(uuid) from public;
grant execute on function booking.public_waitlist_claim(uuid) to anon,authenticated,service_role;
revoke all on function booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function booking._waitlist_notify_entry(bigint,timestamptz) from public,anon,authenticated;
revoke all on function booking._waitlist_process_session(bigint,date) from public,anon,authenticated;
revoke all on function booking.waitlist_sweep() from public,anon,authenticated;
grant execute on function booking.waitlist_sweep() to service_role;

-- Käyttöönotto: tulevien jonotettujen vuorojen nykyinen vapaa kapasiteetti = jo käsitelty (ei näennäistä uutta vapautumista).
insert into booking.waitlist_session_state(rule_id,session_date,offered_free)
select k.rule_id, k.session_date,
       coalesce((select case when s.status='available' then greatest(s.remaining,0) else 0 end
                   from booking._sessions(k.session_date,k.session_date,r.product_id,true) s
                  where s.rule_id=k.rule_id and s.session_date=k.session_date limit 1),0)
  from (select distinct e.rule_id, e.session_date from booking.waitlist_entries e
         where e.status in ('waiting','notified') and e.starts_at>now()) k
  join booking.schedule_rules r on r.id=k.rule_id
on conflict (rule_id,session_date) do nothing;

do $$ begin
  if to_regprocedure('cron.schedule(text,text,text)') is not null
     and not exists (select 1 from cron.job where jobname = 'booking_waitlist_sweep') then
    perform cron.schedule('booking_waitlist_sweep', '* * * * *', 'select booking.waitlist_sweep()');
  end if;
exception when others then
  raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
