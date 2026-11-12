-- Transcript picks added together as one unit (several passages played back
-- to back) share a group key. NULL is a pick on its own.
-- Deploy with the client that understands schema 15; do not apply independently.
ALTER TABLE public.transcript_picks ADD COLUMN "group_key" text;

UPDATE public.schema_version SET version = 15 WHERE id = 1;
