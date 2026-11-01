-- Project language requirements are shared; installation state stays on each Mac.
ALTER TABLE public.projects ADD COLUMN "languages_json" text;

UPDATE public.schema_version SET version = 9 WHERE id = 1;
