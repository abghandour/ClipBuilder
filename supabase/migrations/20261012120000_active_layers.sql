-- Phase 1: portable manual layer choices. Targets may arrive in a later pull.
ALTER TABLE public.videos
    ADD COLUMN IF NOT EXISTS active_run_key TEXT,
    ADD COLUMN IF NOT EXISTS active_transcription_key TEXT;

UPDATE public.schema_version SET version = 4 WHERE id = 1;
