-- ROLLBACK booking_257. Poistaa asiakasviestin RPC:t ja lokitaulun.
-- Ei palauta eikä muuta tapahtuma- tai koulutusviestien funktioita.
set local lock_timeout = '5s';

drop function if exists booking.admin_customer_message_send(date, date, bigint[], text, text, text, text, boolean);
drop function if exists booking.admin_customer_messages_list();
drop function if exists booking._customer_message_recipients(date, date, bigint[]);
drop function if exists booking._customer_message_hits(date, date, bigint[]);
drop function if exists booking._customer_message_product_name(bigint, text);
drop function if exists booking._customer_message_fill(text, jsonb);

drop table if exists booking.customer_messages;
