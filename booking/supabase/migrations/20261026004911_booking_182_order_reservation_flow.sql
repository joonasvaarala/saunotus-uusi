-- booking_182: hallinnan tilaus/varaus-lisäostopolku, oletusarvo pois.
-- Ei muutoksia olemassa oleviin SQL-funktioihin, maksuihin, varauksiin tai dataan.
insert into booking.settings(key, value, description, is_public)
values ('admin_order_reservation_flow_enabled', 'false'::jsonb,
        'Hallinnan tilauksesta varaukseen ja lisäostoihin -toiminto (booking_182)', false)
on conflict (key) do nothing;
