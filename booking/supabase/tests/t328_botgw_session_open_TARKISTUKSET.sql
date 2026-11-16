-- booking_328 jälkitarkistukset (aja vasta migraation jälkeen, ei erillisenä migraationa).
-- Ei muuta tuotantosulkuja, varauksia eikä avaimia. Omistajuustesti tekee tilapäiset
-- rivit tunnisteella booking_328_tarkistus_TEMP ja poistaa ne lopuksi.
-- Odotetut md5:t: call=9a35dfd1d1aa4443df11ede51d49e5fc
--                 help=516aaabd5ffe06d750091c396a12b8b4
--                 svc=9b7d6418ea328318ba6791a6de271d2b
-- otto_has_sessions_close: PRODissa true, DEVissä client_missing (botgw.bot_clients tyhjä).

SELECT 'svc_exists' AS k,
       (to_regprocedure('booking.svc_open_space_block(bigint,text,uuid)') IS NOT NULL)::text AS v
UNION ALL
SELECT 'call_has_session_open',
       (position('when ''session_open'' then' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'session_open_scope_is_sessions_close',
       (position('when ''session_open'' then ''sessions.close''' in pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'no_sessions_open_scope',
       ((SELECT pg_get_constraintdef(oid) FROM pg_constraint
          WHERE conrelid='botgw.bot_clients'::regclass AND conname='bot_clients_scopes_known')
        NOT LIKE '%sessions.open%')::text
UNION ALL
SELECT 'scopes_unchanged',
       ((SELECT md5(pg_get_constraintdef(oid)) FROM pg_constraint
          WHERE conrelid='botgw.bot_clients'::regclass AND conname='bot_clients_scopes_known')
        = 'f69e8c52a98527af3c12c506041607ac')::text
UNION ALL
SELECT 'help_has_session_open',
       (position('"action": "session_open"' in pg_get_functiondef('botgw._action_help(botgw.bot_clients)'::regprocedure)) > 0
        OR position('"action":"session_open"' in pg_get_functiondef('botgw._action_help(botgw.bot_clients)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'call_md5', md5(pg_get_functiondef('botgw.call(text,text,jsonb)'::regprocedure))
UNION ALL
SELECT 'help_md5', md5(pg_get_functiondef('botgw._action_help(botgw.bot_clients)'::regprocedure))
UNION ALL
SELECT 'svc_md5', md5(pg_get_functiondef('booking.svc_open_space_block(bigint,text,uuid)'::regprocedure))
UNION ALL
SELECT 'svc_deactivates_not_deletes',
       ((position('active = false' in pg_get_functiondef('booking.svc_open_space_block(bigint,text,uuid)'::regprocedure)) > 0
         OR position('active=false' in pg_get_functiondef('booking.svc_open_space_block(bigint,text,uuid)'::regprocedure)) > 0)
        AND position('delete from booking.space_blocks' in lower(pg_get_functiondef('booking.svc_open_space_block(bigint,text,uuid)'::regprocedure))) = 0)::text
UNION ALL
SELECT 'svc_rejects_foreign',
       (position('not_own_closure' in pg_get_functiondef('booking.svc_open_space_block(bigint,text,uuid)'::regprocedure)) > 0
        AND position('closure_managed' in pg_get_functiondef('booking.svc_open_space_block(bigint,text,uuid)'::regprocedure)) > 0
        AND position('event_managed' in pg_get_functiondef('booking.svc_open_space_block(bigint,text,uuid)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'svc_not_granted_authenticated',
       (NOT has_function_privilege('authenticated', 'booking.svc_open_space_block(bigint,text,uuid)', 'EXECUTE'))::text
UNION ALL
SELECT 'svc_granted_service_role',
       has_function_privilege('service_role', 'booking.svc_open_space_block(bigint,text,uuid)', 'EXECUTE')::text
UNION ALL
SELECT 'otto_has_sessions_close',
       coalesce((
         SELECT ('sessions.close' = ANY (b.scopes))::text
           FROM botgw.bot_clients b
          WHERE b.name = 'otto-grok-bot'
       ), 'client_missing')
UNION ALL
SELECT 'perm_t1838u',
       (EXISTS (
          SELECT 1 FROM kb.bot_permissions p
           WHERE p.hyvaksynta_viite = 't1838u'
             AND p.botti = 'Oton Grok Bot (botgw otto-grok-bot)'
             AND p.voimassa
             AND p.toimenpide ILIKE '%session_open%'
             AND p.paivamaara = date '2026-11-16'
       ))::text
UNION ALL
SELECT 'perm_id',
       (SELECT p.id::text FROM kb.bot_permissions p
         WHERE p.hyvaksynta_viite = 't1838u' AND p.toimenpide ILIKE '%session_open%'
         ORDER BY p.id DESC LIMIT 1);

-- Omistajuus: vierasta sulkua ei voi avata; oman (created_by + session_close-audit) voi.
-- Tilapäiset rivit merkitään reason/entity-tunnisteella booking_328_tarkistus_TEMP ja poistetaan lopuksi.
-- Ei koske oikeita sulkuja eikä avaimia.
DO $tark$
DECLARE
  v_space bigint;
  v_staff uuid := '00000000-0000-4000-8000-000000000328';
  v_actor text := 'bot:otto-grok-bot';
  v_own bigint;
  v_foreign bigint;
  v_hand bigint;
  v_res jsonb;
  v_marker text := 'booking_328_tarkistus_TEMP';
  v_start timestamptz := timestamptz '2099-01-15 04:00:00+02';
  v_end   timestamptz := timestamptz '2099-01-15 04:05:00+02';
BEGIN
  SELECT r.id INTO v_space FROM booking.resources r WHERE r.code = 'savusauna' AND r.active;
  IF v_space IS NULL THEN
    RAISE EXCEPTION 'booking_328 tarkistus: savusauna-tilaa ei löydy';
  END IF;

  BEGIN
    INSERT INTO booking.space_blocks (space_id, starts_at, ends_at, reason, created_by)
    VALUES (v_space, v_start, v_end, v_marker || ' foreign', NULL)
    RETURNING id INTO v_foreign;

    INSERT INTO booking.space_blocks (space_id, starts_at, ends_at, reason, created_by)
    VALUES (v_space, v_start + interval '10 minutes', v_end + interval '10 minutes', v_marker || ' hand', v_staff)
    RETURNING id INTO v_hand;

    INSERT INTO booking.space_blocks (space_id, starts_at, ends_at, reason, created_by)
    VALUES (v_space, v_start + interval '20 minutes', v_end + interval '20 minutes', v_marker || ' own', v_staff)
    RETURNING id INTO v_own;

    INSERT INTO public.audit_log (actor_kind, actor_name, action, entity_type, entity_id, old_data, new_data)
    VALUES ('staff_bot', v_actor, 'session_close', 'space_block', v_own::text, NULL,
            jsonb_build_object('_via', 'bot-gateway', '_test', v_marker));

    v_res := booking.svc_open_space_block(v_foreign, v_actor, v_staff);
    IF coalesce((v_res->>'ok')::boolean, true) OR v_res->>'error' IS DISTINCT FROM 'not_own_closure' THEN
      RAISE EXCEPTION 'booking_328 tarkistus: vieras sulku olisi pitänyt hylätä (not_own_closure), saatiin %', v_res;
    END IF;
    IF EXISTS (SELECT 1 FROM booking.space_blocks b WHERE b.id = v_foreign AND b.active IS NOT TRUE) THEN
      RAISE EXCEPTION 'booking_328 tarkistus: vieras sulku deaktivoitui';
    END IF;

    -- Sama staff, mutta ei session_close-auditia = hallinnan käsisulku
    v_res := booking.svc_open_space_block(v_hand, v_actor, v_staff);
    IF coalesce((v_res->>'ok')::boolean, true) OR v_res->>'error' IS DISTINCT FROM 'not_own_closure' THEN
      RAISE EXCEPTION 'booking_328 tarkistus: käsisulku olisi pitänyt hylätä (not_own_closure), saatiin %', v_res;
    END IF;
    IF EXISTS (SELECT 1 FROM booking.space_blocks b WHERE b.id = v_hand AND b.active IS NOT TRUE) THEN
      RAISE EXCEPTION 'booking_328 tarkistus: käsisulku deaktivoitui';
    END IF;

    v_res := booking.svc_open_space_block(v_own, v_actor, v_staff);
    IF NOT coalesce((v_res->>'ok')::boolean, false) OR (v_res->>'block_id')::bigint IS DISTINCT FROM v_own THEN
      RAISE EXCEPTION 'booking_328 tarkistus: oman sulun avaus epäonnistui: %', v_res;
    END IF;
    IF EXISTS (SELECT 1 FROM booking.space_blocks b WHERE b.id = v_own AND b.active) THEN
      RAISE EXCEPTION 'booking_328 tarkistus: oma sulku jäi aktiiviseksi';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM booking.space_blocks b WHERE b.id = v_own) THEN
      RAISE EXCEPTION 'booking_328 tarkistus: oma sulku poistettiin, vaikka piti vain deaktivoida';
    END IF;

    v_res := booking.svc_open_space_block(v_own, v_actor, v_staff);
    IF NOT coalesce((v_res->>'ok')::boolean, false) OR coalesce((v_res->>'already')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'booking_328 tarkistus: jo avatun oman sulun piti palauttaa already=true: %', v_res;
    END IF;

    -- siivous
    DELETE FROM public.audit_log a
     WHERE a.entity_type = 'space_block'
       AND a.entity_id IN (v_own::text, v_foreign::text, v_hand::text)
       AND a.new_data->>'_test' = v_marker;
    DELETE FROM booking.space_blocks b
     WHERE b.id IN (v_own, v_foreign, v_hand) AND b.reason LIKE v_marker || '%';

  EXCEPTION WHEN OTHERS THEN
    DELETE FROM public.audit_log a
     WHERE a.new_data->>'_test' = v_marker
        OR (a.entity_type = 'space_block' AND a.entity_id IN (
              COALESCE(v_own::text, ''), COALESCE(v_foreign::text, ''), COALESCE(v_hand::text, '')
            ) AND a.action = 'session_close' AND a.actor_name = v_actor
            AND a.created_at > now() - interval '5 minutes');
    DELETE FROM booking.space_blocks b
     WHERE b.reason LIKE v_marker || '%'
        OR (b.id IN (COALESCE(v_own, -1), COALESCE(v_foreign, -1), COALESCE(v_hand, -1))
            AND b.starts_at >= timestamptz '2099-01-15 00:00:00+02');
    RAISE;
  END;
END
$tark$;

SELECT 'ownership_test' AS k, 'ok' AS v;
