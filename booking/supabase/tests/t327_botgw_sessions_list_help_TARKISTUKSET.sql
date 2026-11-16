-- booking_327 jälkitarkistukset (aja vasta migraation jälkeen, ei erillisenä migraationa).
-- Ei kirjoita tiloja, varauksia eikä avaimia.

SELECT 'call_has_sessions_list' AS k,
       (position('sessions_list' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) > 0)::text AS v
UNION ALL
SELECT 'call_has_help',
       (position('when ''help'' then' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'call_md5', md5(pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure))
UNION ALL
SELECT 'sessions_list_fn',
       (to_regprocedure('botgw._sessions_list(jsonb,botgw.bot_clients)') IS NOT NULL)::text
UNION ALL
SELECT 'help_fn',
       (to_regprocedure('botgw._action_help(botgw.bot_clients)') IS NOT NULL)::text
UNION ALL
SELECT 'sessions_list_md5',
       md5(pg_get_functiondef('botgw._sessions_list(jsonb,botgw.bot_clients)'::regprocedure))
UNION ALL
SELECT 'help_md5',
       md5(pg_get_functiondef('botgw._action_help(botgw.bot_clients)'::regprocedure))
UNION ALL
SELECT 'scopes_has_sessions_read',
       ((SELECT pg_get_constraintdef(oid) FROM pg_constraint
          WHERE conrelid='botgw.bot_clients'::regclass AND conname='bot_clients_scopes_known')
        LIKE '%sessions.read%')::text
UNION ALL
SELECT 'scopes_md5',
       (SELECT md5(pg_get_constraintdef(oid)) FROM pg_constraint
         WHERE conrelid='botgw.bot_clients'::regclass AND conname='bot_clients_scopes_known')
UNION ALL
SELECT 'otto_has_sessions_read_if_present',
       coalesce((
         SELECT ('sessions.read' = any (c.scopes))::text
           FROM botgw.bot_clients c WHERE c.name = 'otto-grok-bot'
       ), 'no_client')
UNION ALL
SELECT 'sessions_list_not_write',
       (position('sessions_list' in split_part(split_part(pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure), 'v_write :=', 2), ';', 1)) = 0)::text
UNION ALL
SELECT 'no_pii_keys_in_list_fn',
       (pg_get_functiondef('botgw._sessions_list(jsonb,botgw.bot_clients)'::regprocedure)
        !~* 'email|phone|phone_e164|order_id|payment|unit_price|base_price|customer')::text
UNION ALL
SELECT 'perm_t1811u_list',
       (EXISTS (
          SELECT 1 FROM kb.bot_permissions p
           WHERE p.hyvaksynta_viite = 't1811u'
             AND p.toimenpide ILIKE '%sessions_list%'
             AND p.voimassa
             AND p.paivamaara = date '2026-11-16'
       ))::text
UNION ALL
SELECT 'perm_id',
       (SELECT p.id::text FROM kb.bot_permissions p
         WHERE p.hyvaksynta_viite = 't1811u' AND p.toimenpide ILIKE '%sessions_list%'
         ORDER BY p.id DESC LIMIT 1);
