-- A transcript pick can be unchecked (kept in the list, left out of the reel).
ALTER TABLE public.transcript_picks ADD COLUMN "kept" integer NOT NULL DEFAULT 1;

UPDATE public.schema_version SET version = 11 WHERE id = 1;
