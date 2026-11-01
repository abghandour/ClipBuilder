-- Highlight History Phase 3 (docs/Highlight-History-Plan.md): projects, their
-- source memberships, highlight history and Express picks. Foreign keys carry
-- parent sync_ids. fight_picks.event_ids is a JSON array of fight_events sync_ids.
-- Local-only columns (profile_name, thumbnail_video_id, ui_state_json,
-- selection_id, take_id, generated_video_id) are not stored here.
-- Apply before shipping the client with understoodSchemaVersion 8.

CREATE TABLE public.projects (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "name" text,
    "created_at" text,
    "last_opened_at" text,
    "archived" bigint,
    "is_home" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX projects_pull ON public.projects (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER projects_stamp BEFORE INSERT OR UPDATE ON public.projects
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.projects FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.projects FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.projects FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.projects FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.projects TO authenticated;

CREATE TABLE public.project_videos (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "project_id" uuid,
    "video_id" uuid,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX project_videos_pull ON public.project_videos (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER project_videos_stamp BEFORE INSERT OR UPDATE ON public.project_videos
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.project_videos ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.project_videos FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.project_videos FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.project_videos FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.project_videos FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.project_videos TO authenticated;

CREATE TABLE public.wizard_highlights (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "project_id" uuid,
    "flow" text,
    "batch_id" text,
    "parent_id" uuid,
    "video_hashes_json" text,
    "footage_json" text,
    "settings_json" text,
    "plan_json" text,
    "provenance_json" text,
    "note" text,
    "author" text,
    "created_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX wizard_highlights_pull ON public.wizard_highlights (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER wizard_highlights_stamp BEFORE INSERT OR UPDATE ON public.wizard_highlights
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.wizard_highlights ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.wizard_highlights FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.wizard_highlights FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.wizard_highlights FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.wizard_highlights FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.wizard_highlights TO authenticated;

CREATE TABLE public.transcript_picks (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "project_id" uuid,
    "position" bigint,
    "start_time" double precision,
    "end_time" double precision,
    "original_start" double precision,
    "original_end" double precision,
    "scene_id" uuid,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX transcript_picks_pull ON public.transcript_picks (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER transcript_picks_stamp BEFORE INSERT OR UPDATE ON public.transcript_picks
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.transcript_picks ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.transcript_picks FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.transcript_picks FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.transcript_picks FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.transcript_picks FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.transcript_picks TO authenticated;

CREATE TABLE public.fight_picks (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "project_id" uuid,
    "position" bigint,
    "start_time" double precision,
    "end_time" double precision,
    "original_start" double precision,
    "original_end" double precision,
    "scene_id" uuid,
    "event_ids" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX fight_picks_pull ON public.fight_picks (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER fight_picks_stamp BEFORE INSERT OR UPDATE ON public.fight_picks
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.fight_picks ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.fight_picks FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.fight_picks FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.fight_picks FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.fight_picks FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.fight_picks TO authenticated;

CREATE TABLE public.qa_picks (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "project_id" uuid,
    "video_id" uuid,
    "scene_id" uuid,
    "position" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX qa_picks_pull ON public.qa_picks (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER qa_picks_stamp BEFORE INSERT OR UPDATE ON public.qa_picks
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.qa_picks ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.qa_picks FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.qa_picks FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.qa_picks FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.qa_picks FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.qa_picks TO authenticated;

UPDATE public.schema_version SET version = 8 WHERE id = 1;
