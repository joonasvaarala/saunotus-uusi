# booking_153 (a): Otto ja Resendin allowlista

Otto (public.staff `2975633f-c53f-48d6-8a38-41cae0be5a83`) on jo tuotannon Resendin testivastaanottajalistalla
(`booking.integration_config('resend').settings.test_recipients`, tarkistettu 24.10.2026). Aiempi käsin ajettava
lisäysskripti `booking_153_otto_allowlist.sql` on poistettu booking_155:ssä, koska sitä ei tarvita. Allowlistaa ei muuteta
migraatioilla eikä skripteillä.

Moottorin sähköpostit Otolle (ja muille) estää `booking.settings` `shift_offer.email_enabled = false`, ei allowlista.
Kun Joonas kääntää asetuksen päälle, sähköpostit lähtevät Resendin tilan (`live`/allowlista) mukaan.

Testi `a` (t153/t155) tarkistaa tämän käytöksen: `email_enabled = false` → `booking.shift_offer_email` ei jonota mitään,
riippumatta siitä, onko Otto allowlistalla.
