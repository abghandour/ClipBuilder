-- Transcript-set provenance. Backups, cleanup proposals and voice profiles are local-only.
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS podcast_transcription_key TEXT;
ALTER TABLE public.transcript_features ADD COLUMN IF NOT EXISTS transcription_key TEXT;
ALTER TABLE public.topic_ranges ADD COLUMN IF NOT EXISTS transcription_key TEXT;

-- Older rows have no reliable source-set provenance and are recomputed on demand.
UPDATE public.schema_version SET version = 5 WHERE id = 1;
