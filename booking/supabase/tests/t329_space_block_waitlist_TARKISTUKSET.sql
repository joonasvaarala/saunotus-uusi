-- booking_329 tarkistukset (vain SELECT; aja migraation jälkeen DEV/PROD).
-- 1) _sessions on 329-versio
select md5(pg_get_functiondef('booking._sessions(date,date,bigint,boolean)'::regprocedure)) = '9fba454852769a41afdd3a183e460298' as sessions_329;
-- 2) jonotriggeri olemassa ja kutsuu oikeaa funktiota
select t.tgname, p.proname, t.tgenabled from pg_trigger t join pg_proc p on p.oid = t.tgfoid
 where t.tgrelid = 'booking.space_blocks'::regclass and t.tgname = 'space_blocks_zz_waitlist';
-- 3) yleiset vuorot, joiden päällä on aktiivinen oma käsisulku → status 'full', remaining 0
select s.session_date, s.rule_id, s.mode, s.status, s.remaining
  from booking.space_blocks b
  join booking.schedule_rules sr on sr.space_id = b.space_id
  cross join lateral booking._sessions((b.starts_at at time zone 'Europe/Helsinki')::date, (b.starts_at at time zone 'Europe/Helsinki')::date) s
 where b.active and b.closure_event_id is null and b.event_block_id is null and b.ends_at > now()
   and s.rule_id = sr.id and s.mode <> 'exclusive' and s.starts_at < b.ends_at and s.ends_at > b.starts_at
 order by 1, 2;
