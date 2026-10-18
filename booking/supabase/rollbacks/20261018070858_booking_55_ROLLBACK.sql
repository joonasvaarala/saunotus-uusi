-- ROLLBACK booking_55_articles_redirects
set local lock_timeout = '5s';
drop function if exists booking.public_articles_redirects();
