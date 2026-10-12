-- Fight scoring v2: attempt sequences (takedown / submission) carry a target,
-- a resolution time, an outcome and a hold type; rows record the scoring
-- prompt version. All nullable so older clients keep syncing.
ALTER TABLE public.fight_events
    ADD COLUMN "target_key" text,
    ADD COLUMN "end_time" double precision,
    ADD COLUMN "outcome" text,
    ADD COLUMN "detail" text,
    ADD COLUMN "scoring_version" integer;
