-- ROLLBACK booking_110_pos_link_email.
-- Poistaa vain tämän migraation funktiot. Ei palauta eikä muuta muita funktioita,
-- resend-tilaa tai vismapay-tilaa.

drop function if exists booking.admin_pos_email_status(bigint);
drop function if exists booking.admin_pos_send_link(bigint, text, boolean);
