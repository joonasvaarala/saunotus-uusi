-- booking_275 ROLLBACK: poistaa vain booking_275:n luomat funktiot
-- public.svc_shift_offer_start(uuid, text, uuid[], text, text, boolean, boolean)
-- ja public.svc_shift_offer_cancel(uuid, text, boolean).
-- Vanhaa svc_shift_offer_cancel(uuid, boolean, text, boolean) -määrittelyä ei ole
-- tallessa, joten sitä ei palauteta; rollback poistaa vain 275:n funktiot.
-- Aja booking_273-rollback vasta tämän jälkeen, jos 273:kin perutaan
-- (275 on myöhempi; tämä rollback vain pudottaa 275:n funktiot eikä riipu 273:n tilasta).

drop function if exists public.svc_shift_offer_start(uuid, text, uuid[], text, text, boolean, boolean);
drop function if exists public.svc_shift_offer_cancel(uuid, text, boolean);
