-- booking_100_giftpkg_entry2_name (19.10.2026)
-- entry_2:n tuotenimi vastaa tuotantoa: Savusaunavuoro kahdelle / Smoke sauna session for two.
-- booking_43:n siemen jää ennalleen (Sisäänpääsy kahdelle). Tämä ajaa nimen sen jälkeen,
-- jotta tyhjä kanta ei jää vanhaan nimeen eikä uudelleenajo kirjoita nimeä uudestaan.
-- Vain name ja name_en. code, hinta, ALV, kuvaus, items ja sort_order eivät muutu.
-- Jos nimet ovat jo uudet, UPDATE ei koske riviin: zz_site_text_sync (booking_60) ei tee uutta site_texts-versiota.
-- Tuotannossa nimi on jo vaihdettu, joten siellä tämä on no-op.
-- Rollback: rollbacks/20261019000100_booking_100_ROLLBACK.sql

update booking.gift_card_packages
   set name = 'Savusaunavuoro kahdelle',
       name_en = 'Smoke sauna session for two'
 where code = 'entry_2'
   and (name is distinct from 'Savusaunavuoro kahdelle'
     or name_en is distinct from 'Smoke sauna session for two');
