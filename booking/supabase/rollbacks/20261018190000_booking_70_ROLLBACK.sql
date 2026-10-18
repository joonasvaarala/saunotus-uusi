-- ROLLBACK booking_70_sales_chart. Poistaa vain lukufunktion admin_sales_chart. Ei taulu- eikä datamuutoksia.
-- Raportit, CSV, kuitit ja statistics.johku ennallaan.
drop function if exists booking.admin_sales_chart(integer);
