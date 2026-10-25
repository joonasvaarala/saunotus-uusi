-- Peruutus migraatioille 20261025145539_botgw_otto_disabled + 20261025151402_botgw_otto_scope_v2 (koko botgw pois).
-- Lähde: Bottiavustuksen rollback_botgw.sql. Ajetaan vain Joonaksen luvalla. Poista ensin edge-funktio bot-gateway tai aseta BOTGW_DISABLED=1.
-- Peru botgw kokonaan (v1 + v2; ei koske muihin tauluihin, audit_log/shift_change_log-historia jää).
drop function if exists public.botgw_log_failure(text, text, text);
drop function if exists public.botgw_call(text, text, jsonb);
drop schema if exists botgw cascade;
