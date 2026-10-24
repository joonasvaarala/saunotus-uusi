-- pre154: ajetaan ENNEN booking_154-migraatiota (sitoutuu, ei transaktion kumousta). Luo "olemassa olevan" hallinnan
-- kortin (kuten tuotannon kortti 24) ja ostetun kortin, jotta t154 voi todeta, ettei migraatio luo niille outbox-rivejä.
-- Kaikki data on feikkiä (@example.test).
insert into booking.customers(name, email) values ('Vanha Kortti', 'vanha154@example.test');
insert into booking.annual_cards(customer_id, valid_from, valid_to, notes)
  select id, current_date - 10, current_date + 355, 'pre154' from booking.customers where email = 'vanha154@example.test';
