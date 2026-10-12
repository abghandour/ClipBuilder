-- Portable canonical analysis inputs, shared with every successful run.
ALTER TABLE public.analysis_runs ADD COLUMN IF NOT EXISTS request_hash TEXT;
ALTER TABLE public.analysis_runs ADD COLUMN IF NOT EXISTS request_json TEXT;

UPDATE public.schema_version SET version = 6 WHERE id = 1;
