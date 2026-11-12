-- A transcript pick records the transcript set it was made on, so every Mac
-- lists and removes one set's picks instead of every set's. NULL (a pick from
-- an older client) shows under every set.
-- Deploy with the client that understands schema 14; do not apply independently.
ALTER TABLE public.transcript_picks ADD COLUMN "transcription_key" text;

UPDATE public.schema_version SET version = 14 WHERE id = 1;
