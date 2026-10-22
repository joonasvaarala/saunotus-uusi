-- PALUU: purkaa 20261022022221_shift_offer_response_page.sql.
-- Ei koske tarjouksiin eikä WhatsApp-lähettäjään.

drop function if exists public.shift_offer_respond_as_staff(text, uuid, text, timestamptz);
drop function if exists public.shift_offer_open_for_token(text);
