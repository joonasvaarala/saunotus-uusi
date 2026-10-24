-- booking_144 ROLLBACK: poistaa vain booking_144:n rakenteet. HUOM: mittaustapahtumat (booking.analytics_events) poistuvat peruuttamattomasti.
-- Ei koske muihin funktioihin (vuosikortti/alennuskoodi booking_142/143 ennallaan).
begin;
drop function if exists booking.admin_analytics_summary(date, date);
drop function if exists booking.public_track_event(jsonb);
drop function if exists booking._analytics_source(text, text, text);
drop table if exists booking.analytics_events;
commit;
