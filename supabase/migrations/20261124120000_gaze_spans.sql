-- Stored gaze spans, including a kind='none' marker for measured tiles with no glances.
-- video_id carries videos.sync_id; person_key is the portable people.key.
-- Apply only with the release that ships the schema 16 client.

CREATE TABLE public.gaze_spans (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "tile" bigint NOT NULL DEFAULT 0,
    "person_key" text,
    "start_time" double precision,
    "end_time" double precision,
    "kind" text,
    "meter_version" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX gaze_spans_pull ON public.gaze_spans (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER gaze_spans_stamp BEFORE INSERT OR UPDATE ON public.gaze_spans
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.gaze_spans ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.gaze_spans FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.gaze_spans FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.gaze_spans FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.gaze_spans FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.gaze_spans TO authenticated;

UPDATE public.schema_version SET version = 16 WHERE id = 1;
