-- Rollback booking_60: poistaa tekstijärjestelmän (taulut, funktiot, triggerit, rooli text_editor, oikeudet, asetus). Lähdedata (kb/booking-taulujen tekstit) EI muutu.
-- HUOM: jos tekstejä on julkaistu järjestelmän kautta, lähdetauluissa ovat jo uudet tekstit (ne säilyvät); versiohistoria poistuu.
set local lock_timeout = '5s';
do $$
declare x text;
begin
  foreach x in array array['kb.products', 'kb.faq', 'kb.policies', 'kb.locations', 'kb.opening_hours', 'kb.event_dates', 'kb.businesses',
                           'booking.addons', 'booking.product_options', 'booking.gift_card_packages', 'booking.schedule_rules'] loop
    execute format('drop trigger if exists zz_site_text_sync on %s', x);
  end loop;
end $$;
drop policy if exists site_texts_staff_read on booking.site_texts;
drop policy if exists site_text_versions_staff_read on booking.site_text_versions;
drop function if exists booking.public_get_site_texts(text);
drop function if exists booking.admin_texts_drift();
drop function if exists booking.admin_texts_sync();
drop function if exists booking.admin_texts_set_class(text, text, text, text);
drop function if exists booking.admin_texts_rollback(text, text, integer, text);
drop function if exists booking.admin_texts_reject(bigint, text);
drop function if exists booking.admin_texts_publish(bigint);
drop function if exists booking.admin_texts_approve(bigint, text, boolean);
drop function if exists booking.admin_texts_queue(boolean, integer);
drop function if exists booking.texts_get(text, text);
drop function if exists booking.texts_list(text, text, text, boolean, integer, integer);
drop function if exists booking.texts_withdraw(bigint);
drop function if exists booking.texts_submit(bigint);
drop function if exists booking.texts_propose(text, text, text, text, boolean);
drop function if exists booking._text_source_changed();
drop function if exists booking._texts_register_sources();
drop function if exists booking._texts_reg(text, text, text, text, text, text, text, text, integer);
drop function if exists booking._text_json(booking.site_texts);
drop function if exists booking._text_need_approve(boolean);
drop function if exists booking._text_row(text, text, boolean);
drop function if exists booking._text_publish(bigint);
drop function if exists booking._text_refresh(bigint);
drop function if exists booking._text_audit(text, bigint, integer, jsonb);
drop function if exists booking._text_actor_kind();
drop function if exists booking._text_validate(text, text, integer, text[], text);
drop function if exists booking._text_escalation(text, text);
drop function if exists booking._text_tokens(text, text);
drop function if exists booking._text_perm_any(text[]);
drop function if exists booking._text_perm(text);
drop function if exists booking._text_has(text);
drop function if exists booking._text_bot_role();
drop function if exists booking._text_is_service();
drop table if exists booking.site_text_versions;
drop table if exists booking.site_texts;
drop table if exists booking.text_bots;
delete from booking.role_permissions where permission in ('texts.propose', 'texts.approve', 'texts.approve_protected', 'texts.manage');
delete from booking.roles where code = 'text_editor';
delete from booking.settings where key = 'texts_max_proposals_per_day';
