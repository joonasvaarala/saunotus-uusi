-- rollback booking_294 (ei koske jo tehtyihin siirtoihin; ne näkyvät audit_logissa SVC_MOVE_RESERVATION_TO_RULE)
drop function if exists booking.svc_move_reservation_to_rule(bigint, bigint, bigint, timestamptz, text, text, text, boolean);
update kb.bot_permissions set voimassa = false
 where botti_id = 'fefd4229-b9f6-425c-ba91-381135ef01b7' and toimenpide like 'booking.svc_move_reservation_to_rule%';
