-- Apply before shipping the client with understoodSchemaVersion 7.
ALTER TABLE public.video_people
    ADD COLUMN IF NOT EXISTS vip boolean,
    ADD COLUMN IF NOT EXISTS vip_source text;

UPDATE public.schema_version SET version = 7 WHERE id = 1;
