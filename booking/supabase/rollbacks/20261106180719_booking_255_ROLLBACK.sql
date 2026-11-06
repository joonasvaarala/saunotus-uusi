-- booking_255 rollback. Poistaa työtilan lisätiedot/jonot/esikatselut; ota tarvittaessa talteen ensin.
-- EI palauta jo lähetettyjä viestejä, jo tehtyjä maksuja tai luotuja kopioita. Tilasulut jäävät nykyiseen hallintaan.
-- Ei ajeta automaattisesti.
do $$ declare f record; begin for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='booking' and p.proname=any(array['training_details_anonymize','_training_work_rule','admin_training_people','admin_training_work_get','admin_training_work_list','admin_training_work_save','admin_training_person_save','admin_training_space_add','admin_training_space_cancel','admin_calendar_space_blocks','admin_training_waitlist_add','admin_training_waitlist_update','admin_training_person_add','_training_message_recipients','admin_training_message_preview','admin_training_message_send','admin_training_session_copy','admin_training_prepare_balance','admin_training_payment_link','admin_training_payment_links']) loop execute format('drop function %s cascade',f.sig); end loop; end $$;
drop table if exists booking.training_message_previews;
drop table if exists booking.training_waitlist;
drop table if exists booking.training_participant_details;
drop table if exists booking.training_session_work;
drop table if exists booking.training_product_groups;
