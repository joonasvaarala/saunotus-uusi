-- booking_193: Hoidot (time_window_class 'therapy') päättyvät kaikkina päivinä viimeistään klo 20:00 (Europe/Helsinki).
-- Pyyntö t1053u (Joonas). Aiemmin latest_end oli 20:30 (ma–pe ja la–su).
-- Idempotentti: lyhentää vain yli 20:00 olevat päättymisajat; aiempia ei pidennetä.
-- Slottien generointi (_treatment_availability_core -> _time_window_violation) ja varauksen tarkistus
-- (_treatment_slot_check, trigger reservations_time_window) tarkistavat jo loppuajan (start + kesto) eikä vain alkua,
-- joten viimeinen alkuaika = 20:00 - kesto (60 min -> 19:00, 120 min -> 18:00, 180 min -> 17:00).
-- Saunottajan työvuorot (public.work_shifts) kuuluvat vuorosuunnittelulle eikä niitä muuteta tässä.
update booking.time_window_rules
   set latest_end = time '20:00'
 where class = 'therapy'
   and latest_end is not null
   and latest_end > time '20:00';
