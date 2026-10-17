-- booking_21_ritual_pool_1730 (17.10.2026): paketti kb 7 "Saunarituaali ja savusaunavuoro" voi alkaa 17:00.
-- Paketin rakenne: leg 2 = Rauni-seremonia (rituaalipooli, 20 min, alkaa varauksen alussa), leg 1 = savusaunavuoro joka alkaa +30 min ja kestää 90 min.
-- _plan_legs hakee savusaunaosan poolin koodista start_pool_prefix || HH24MI(savusaunaosan alku) ('yleinen_vkp_' + 1630 / 1700 / 1730).
-- Alkuajat 16:00 ja 16:30 toimivat jo (poolit 1630 ja 1700); 17:00 -> 17:30 puuttui, joten kb 7 17:00 -> no_pool_for_start.
-- Korjaus on datatason: uusi kapasiteettipooli (6 hlö) savusaunalle. Ei funktiomuutoksia, ei julkista sääntöä (ei näy kaupassa), ei vaikutusta yleisiin vuoroihin.
insert into booking.resources(code, name, kind, parent_id, capacity, active, sort_order, notes, buffer_after_min, session_exclusive, is_ritual_pool)
select 'yleinen_vkp_1730', 'Paketti kb 7: savusaunaosa alkaa 17:30 (paikat / vuoro)', 'capacity_pool', s.id, 6, true, 37,
       'Paketin kb 7 (rituaali Raunissa 17:00–17:20) savusaunaosa 17:30–19:00: 6 hlö per vuoro. Ei yleisen vuoron sääntöä (ei näy kaupassa).', 0, false, false
  from booking.resources s where s.code = 'savusauna'
on conflict (code) do nothing;
