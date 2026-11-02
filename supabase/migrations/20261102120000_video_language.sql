-- Every video carries a language and where it came from (user, transcript, detected).
ALTER TABLE public.videos ADD COLUMN "language" text;
ALTER TABLE public.videos ADD COLUMN "language_source" text;

UPDATE public.schema_version SET version = 10 WHERE id = 1;
