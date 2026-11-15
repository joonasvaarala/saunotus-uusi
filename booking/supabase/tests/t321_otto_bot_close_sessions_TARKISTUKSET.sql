-- booking_321 jälkitarkistukset (aja vasta migraation jälkeen, ei erillisenä migraationa).
-- Odotetut md5:t: call=59cbd540a8775b841c566b4f73b507e9
--                 svc=680ca33d9ca60e14acad15a027e39592
--                 scopes_con=21afc1fc9a63a356d1c3eb07ea279376
-- otto_has_scope: PRODissa true, DEVissä client_missing (botgw.bot_clients tyhjä).

-- 1) Funktiot ja md5
SELECT 'svc_exists' AS k,
       (to_regprocedure('booking.svc_create_space_block(bigint,timestamptz,timestamptz,text,text,uuid)') IS NOT NULL)::text AS v
UNION ALL
SELECT 'call_has_session_close',
       (position('session_close' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'call_no_session_open',
       (position('session_open' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) = 0)::text
UNION ALL
SELECT 'call_md5', md5(pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure))
UNION ALL
SELECT 'svc_md5', md5(pg_get_functiondef('booking.svc_create_space_block(bigint,timestamptz,timestamptz,text,text,uuid)'::regprocedure))
UNION ALL
SELECT 'scopes_has_sessions_close',
       (pg_get_constraintdef(c.oid) LIKE '%sessions.close%')::text
  FROM pg_constraint c
 WHERE c.conrelid = 'botgw.bot_clients'::regclass AND c.conname = 'bot_clients_scopes_known'
UNION ALL
SELECT 'scopes_con_md5', md5(pg_get_constraintdef(c.oid))
  FROM pg_constraint c
 WHERE c.conrelid = 'botgw.bot_clients'::regclass AND c.conname = 'bot_clients_scopes_known'
UNION ALL
SELECT 'otto_has_scope',
       coalesce((
         SELECT ('sessions.close' = ANY (b.scopes))::text
           FROM botgw.bot_clients b
          WHERE b.name = 'otto-grok-bot'
       ), 'client_missing')
UNION ALL
SELECT 'perm_t1811u',
       (EXISTS (
          SELECT 1 FROM kb.bot_permissions p
           WHERE p.hyvaksynta_viite = 't1811u'
             AND p.botti = 'Oton Grok Bot (botgw otto-grok-bot)'
             AND p.voimassa
             AND p.toimenpide ILIKE '%session_close%'
       ))::text
UNION ALL
SELECT 'svc_not_granted_authenticated',
       (NOT has_function_privilege('authenticated', 'booking.svc_create_space_block(bigint,timestamptz,timestamptz,text,text,uuid)', 'EXECUTE'))::text
UNION ALL
SELECT 'svc_granted_service_role',
       has_function_privilege('service_role', 'booking.svc_create_space_block(bigint,timestamptz,timestamptz,text,text,uuid)', 'EXECUTE')::text;
