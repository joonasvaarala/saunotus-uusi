-- HISTORY-SYNC: public.sync_state -perusrakenne (Google-kalenterisynkan tila per kalenterilähde). EI AJETA TUOTANTOON.
-- Taulu on tuotannossa (Supabase sxbofnuisemspgquoxyv) jo olemassa: luotu alun perin migraatiossa 20261009140238 calendar_sync_schema
-- (ennen tämän repon migraatioketjua) ja sarakkeet lisätty myöhemmin. Rakenne koottu tuotannon katalogista 25.10.2026
-- (/workspace/backlog_v2/sync_state_schema.sql, md5 7222ff5dec8552b2f7e422652959fe31), jotta repopohjainen rakennus luo taulun
-- ennen sitä käyttäviä migraatioita (20261021224956_apply_calendar_changes_v2, 20261022081002_ops_health_varmistaja).
-- Täysin idempotentti: olemassa olevaan tuotannon tauluun ajettuna ei muuttaisi mitään (if not exists / DO-vartijat / idempotentit grantit).
-- Riippuvuudet, joita tämä repon ketju EI luo (tuotannossa ennen ketjua olemassa): public.calendar_sources(id), public.set_updated_at().

CREATE TABLE IF NOT EXISTS public.sync_state (
    calendar_source_id   uuid        NOT NULL,
    sync_token           text,
    last_success_at      timestamptz,
    last_attempt_at      timestamptz,
    last_error           text,
    updated_at           timestamptz NOT NULL DEFAULT now(),
    full_sync_required   boolean     NOT NULL DEFAULT false,
    last_full_sync_at    timestamptz,
    last_sync_kind       text,
    consecutive_failures integer     NOT NULL DEFAULT 0,
    lease_owner          text,
    lease_until          timestamptz,
    CONSTRAINT sync_state_pkey PRIMARY KEY (calendar_source_id),
    CONSTRAINT sync_state_calendar_source_id_fkey FOREIGN KEY (calendar_source_id)
        REFERENCES public.calendar_sources (id) ON DELETE CASCADE,
    CONSTRAINT sync_state_last_sync_kind_check CHECK (
        (last_sync_kind IS NULL) OR (last_sync_kind = ANY (ARRAY['incremental'::text, 'full'::text, 'recovery'::text]))
    )
);

-- Rajoitteet vain jos puuttuvat (taulu voi olla olemassa ilman niitä); tuotannossa kaikki kolme ovat jo olemassa.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.sync_state'::regclass AND conname = 'sync_state_pkey') THEN
    ALTER TABLE public.sync_state ADD CONSTRAINT sync_state_pkey PRIMARY KEY (calendar_source_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.sync_state'::regclass AND conname = 'sync_state_calendar_source_id_fkey') THEN
    ALTER TABLE public.sync_state ADD CONSTRAINT sync_state_calendar_source_id_fkey FOREIGN KEY (calendar_source_id)
        REFERENCES public.calendar_sources (id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.sync_state'::regclass AND conname = 'sync_state_last_sync_kind_check') THEN
    ALTER TABLE public.sync_state ADD CONSTRAINT sync_state_last_sync_kind_check CHECK (
        (last_sync_kind IS NULL) OR (last_sync_kind = ANY (ARRAY['incremental'::text, 'full'::text, 'recovery'::text])));
  END IF;
END $$;

COMMENT ON COLUMN public.sync_state.sync_token IS
    'Last WORKING Google nextSyncToken. Only replaced inside a successful apply_calendar_changes transaction; never cleared on errors.';

-- Indeksit: vain pääavaimen indeksi (sync_state_pkey, btree calendar_source_id).

-- Triggeri vain jos puuttuu (ei drop+create: tuotannossa ei muutosta eikä lukitusta).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.sync_state'::regclass AND tgname = 'sync_state_updated_at' AND NOT tgisinternal) THEN
    CREATE TRIGGER sync_state_updated_at
        BEFORE UPDATE ON public.sync_state
        FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $$;

-- RLS päällä, EI forced, EIKÄ politiikkoja (kuten tuotannossa): anon/authenticated eivät näe rivejä tauluoikeuksista huolimatta;
-- vain service_role (BYPASSRLS) ja omistaja (postgres) lukevat/kirjoittavat.
ALTER TABLE public.sync_state ENABLE ROW LEVEL SECURITY;

-- Omistaja ja oikeudet kuten tuotannossa: relacl
-- {postgres=arwdDxtm, anon=arwdDxtm, authenticated=arwdDxtm, service_role=arwdDxtm, backup_reader=r}
-- (backup_reader luodaan migraatiossa 20261019140000_ops_001_backup_reader.)
ALTER TABLE public.sync_state OWNER TO postgres;
GRANT ALL ON TABLE public.sync_state TO anon;
GRANT ALL ON TABLE public.sync_state TO authenticated;
GRANT ALL ON TABLE public.sync_state TO service_role;
GRANT SELECT ON TABLE public.sync_state TO backup_reader;
