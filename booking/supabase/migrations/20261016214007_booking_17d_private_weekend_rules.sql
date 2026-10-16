-- DRAFT (EI AJETTU) 17.10.2026 – booking_17d_private_weekend_rules: yksityisvuorosäännöt viikonlopun julkisten vuorojen ikkunoille (DESIGN B6b/B7, Joonas E10)
-- Jokaiselle viikonlopun julkiselle 2 h -vuorolle (alut 14:00, 14:30, 15:00, 16:00, 16:30, 17:00) luodaan vastaava "Oma savusaunavuoro" -sääntö (kb 25) samalle ajalle.
-- Säännöt luodaan EI-AKTIIVISINA (active=false): mitään ei tule myyntiin ennen kuin Joonas aktivoi ne hallinnassa (hinta = kopio sääntö 15:stä: la–su 13–15 / 2 h).
-- Moottori on jo puoliavoin [alku, loppu): 15:00 päättyvä yksityisvuoro sallii 15:00 alkavan julkisen; 19:00 päättyvä julkinen sallii 19:00 alkavan yksityisen.
-- Viikonlopun yleiset vuorot ovat jo 2 h (säännöt 6–11, kb 1); "30 min -> 2 h" (O7) koskee vain tuontia (transform.py), ei sääntöjä.
set local search_path = booking, extensions, public;

insert into booking.schedule_rules (product_id, label, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to, min_persons, max_persons,
                                    price_mode, price_variant_id, included_persons, extra_person_price, deadline_minutes, active, sort_order, notes)
select src.product_id,
       'Oma savusaunavuoro la–su ' || to_char(t.st, 'HH24:MI') || '–' || to_char(t.st + interval '2 hours', 'HH24:MI') || ' (2 h, julkista vuoroa vastaava)',
       src.mode, src.space_id, src.weekdays, t.st, 120, src.valid_from, src.valid_to, src.min_persons, src.max_persons,
       src.price_mode, src.price_variant_id, src.included_persons, src.extra_person_price, src.deadline_minutes,
       false,                                                                    -- EI aktiivinen: Joonas aktivoi
       src.sort_order, 'booking_17d: vastaa viikonlopun julkista vuoroa; aktivoi hallinnassa kun hinta/saatavuus vahvistettu'
  from booking.schedule_rules src
 cross join (values ('14:00'::time), ('14:30'), ('15:00'), ('16:00'), ('16:30'), ('17:00')) t(st)
 where src.product_id = 25 and src.weekdays = '{6,7}' and src.start_time = '13:00' and src.duration_minutes = 120
   and not exists (select 1 from booking.schedule_rules x where x.product_id = 25 and x.weekdays = '{6,7}' and x.start_time = t.st and x.duration_minutes = 120);
