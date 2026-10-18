-- ROLLBACK booking_100_giftpkg_entry2_name.
-- Palauttaa vain entry_2:n nimen booking_43:n siemeneen. Hinta, ALV, code, kuvaus ja items ennallaan.
-- Jos zz_site_text_sync on käytössä, nimen palautus julkaisee site_texts-avaimeen giftpkg.entry_2.name uuden version.
-- Idempotentti: ei kirjoita, jos nimet ovat jo vanhat.

update booking.gift_card_packages
   set name = 'Sisäänpääsy kahdelle',
       name_en = 'Admission for two'
 where code = 'entry_2'
   and (name is distinct from 'Sisäänpääsy kahdelle'
     or name_en is distinct from 'Admission for two');
