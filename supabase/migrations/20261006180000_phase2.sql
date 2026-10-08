-- Phase 2: footage metadata only. Local media paths never enter these tables.

CREATE TABLE public.videos (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "hash" text,
    "filename" text,
    "duration" double precision,
    "width" bigint,
    "height" bigint,
    "wide" bigint,
    "discovered_at" text,
    "analyzed_at" text,
    "podcast_layout" text,
    "podcast_seam_x" double precision,
    "podcast_layout_confidence" double precision,
    "podcast_tiles_json" text,
    "created_at" text,
    "drive_file_id" text,
    "drive_link" text,
    "analyzer_provider" text,
    "visual_analyzer_provider" text,
    "speech_analyzer_provider" text,
    "analyzer_model" text,
    "visual_analyzer_model" text,
    "speech_analyzer_model" text,
    "visual_analyzed_at" text,
    "speech_analyzed_at" text,
    "video_type" text,
    "naming_provider" text,
    "naming_model" text,
    "people_provider" text,
    "people_model" text,
    "people_detected_at" text,
    "speech_seconds" double precision,
    "people_seconds" double precision,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX videos_pull ON public.videos (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER videos_stamp BEFORE INSERT OR UPDATE ON public.videos
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.videos ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.videos FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.videos FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.videos FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.videos FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.videos TO authenticated;

CREATE TABLE public.analysis_runs (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "name" text,
    "instructions" text,
    "provider" text,
    "model" text,
    "has_transcript" bigint,
    "sample_interval" double precision,
    "notes_json" text,
    "created_at" text,
    "settings_json" text,
    "models_json" text,
    "run_key" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX analysis_runs_pull ON public.analysis_runs (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER analysis_runs_stamp BEFORE INSERT OR UPDATE ON public.analysis_runs
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.analysis_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.analysis_runs FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.analysis_runs FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.analysis_runs FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.analysis_runs FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.analysis_runs TO authenticated;

CREATE TABLE public.scenes (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "run_id" uuid,
    "start_time" double precision,
    "end_time" double precision,
    "excluded" bigint,
    "ignored" bigint,
    "favorite" bigint,
    "favorite_provider" text,
    "favorite_model" text,
    "crop_x_frac" double precision,
    "free_crops" text,
    "curated" bigint,
    "edit_start" double precision,
    "edit_end" double precision,
    "narrative" text,
    "score" double precision,
    "excitement" double precision,
    "parent_scene_id" uuid,
    "models_json" text,
    "curated_provider" text,
    "curated_model" text,
    "stack_choice" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX scenes_pull ON public.scenes (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER scenes_stamp BEFORE INSERT OR UPDATE ON public.scenes
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.scenes ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.scenes FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.scenes FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.scenes FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.scenes FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.scenes TO authenticated;

CREATE TABLE public.scene_tags (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "scene_id" uuid,
    "tag" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX scene_tags_pull ON public.scene_tags (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER scene_tags_stamp BEFORE INSERT OR UPDATE ON public.scene_tags
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.scene_tags ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.scene_tags FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.scene_tags FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.scene_tags FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.scene_tags FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.scene_tags TO authenticated;

CREATE TABLE public.moments (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "at_time" double precision,
    "note" text,
    "dialog" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX moments_pull ON public.moments (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER moments_stamp BEFORE INSERT OR UPDATE ON public.moments
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.moments ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.moments FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.moments FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.moments FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.moments FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.moments TO authenticated;

CREATE TABLE public.transcripts (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "transcription_key" text,
    "transcription_created_at" text,
    "language" text,
    "is_translation" bigint,
    "start_time" double precision,
    "end_time" double precision,
    "text" text,
    "provider" text,
    "model" text,
    "original_text" text,
    "words" text,
    "technique" text,
    "seconds" double precision,
    "speaker_key" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX transcripts_pull ON public.transcripts (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER transcripts_stamp BEFORE INSERT OR UPDATE ON public.transcripts
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.transcripts ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.transcripts FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.transcripts FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.transcripts FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.transcripts FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.transcripts TO authenticated;

CREATE TABLE public.speaker_turns (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "transcription_key" text,
    "transcription_created_at" text,
    "start_time" double precision,
    "end_time" double precision,
    "cluster" bigint,
    "confidence" double precision,
    "picture_side" text,
    "picture_confidence" double precision,
    "resolved_side" text,
    "person_key" text,
    "tile" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX speaker_turns_pull ON public.speaker_turns (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER speaker_turns_stamp BEFORE INSERT OR UPDATE ON public.speaker_turns
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.speaker_turns ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.speaker_turns FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.speaker_turns FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.speaker_turns FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.speaker_turns FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.speaker_turns TO authenticated;

CREATE TABLE public.transcript_features (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "start_time" double precision,
    "end_time" double precision,
    "text" text,
    "speaker_key" text,
    "energy" double precision,
    "kind" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX transcript_features_pull ON public.transcript_features (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER transcript_features_stamp BEFORE INSERT OR UPDATE ON public.transcript_features
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.transcript_features ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.transcript_features FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.transcript_features FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.transcript_features FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.transcript_features FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.transcript_features TO authenticated;

CREATE TABLE public.topic_ranges (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "title" text,
    "start_time" double precision,
    "end_time" double precision,
    "summary" text,
    "speaker_keys_json" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX topic_ranges_pull ON public.topic_ranges (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER topic_ranges_stamp BEFORE INSERT OR UPDATE ON public.topic_ranges
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.topic_ranges ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.topic_ranges FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.topic_ranges FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.topic_ranges FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.topic_ranges FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.topic_ranges TO authenticated;

CREATE TABLE public.video_people (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "person_id" uuid,
    "portrait_at" double precision,
    "portrait_json" text,
    "ranges_json" text,
    "detected_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX video_people_pull ON public.video_people (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER video_people_stamp BEFORE INSERT OR UPDATE ON public.video_people
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.video_people ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.video_people FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.video_people FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.video_people FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.video_people FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.video_people TO authenticated;

CREATE TABLE public.person_markers (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "at_time" double precision,
    "x" double precision,
    "y" double precision,
    "width" double precision,
    "height" double precision,
    "person_id" uuid,
    "ignored" bigint,
    "created_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX person_markers_pull ON public.person_markers (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER person_markers_stamp BEFORE INSERT OR UPDATE ON public.person_markers
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.person_markers ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.person_markers FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.person_markers FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.person_markers FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.person_markers FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.person_markers TO authenticated;

CREATE TABLE public.video_subjects (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "name" text,
    "color_index" bigint,
    "rects_json" text,
    "created_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX video_subjects_pull ON public.video_subjects (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER video_subjects_stamp BEFORE INSERT OR UPDATE ON public.video_subjects
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.video_subjects ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.video_subjects FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.video_subjects FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.video_subjects FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.video_subjects FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.video_subjects TO authenticated;

CREATE TABLE public.video_notes (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "at_time" double precision,
    "note" text,
    "created_at" text,
    "provider" text,
    "model" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX video_notes_pull ON public.video_notes (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER video_notes_stamp BEFORE INSERT OR UPDATE ON public.video_notes
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.video_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.video_notes FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.video_notes FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.video_notes FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.video_notes FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.video_notes TO authenticated;

CREATE TABLE public.grades (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "scene_id" uuid,
    "score" bigint,
    "graded_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX grades_pull ON public.grades (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER grades_stamp BEFORE INSERT OR UPDATE ON public.grades
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.grades ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.grades FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.grades FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.grades FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.grades FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.grades TO authenticated;

CREATE TABLE public.fight_events (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "at_time" double precision,
    "fighter_key" text,
    "action" text,
    "points" double precision,
    "provider" text,
    "model" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX fight_events_pull ON public.fight_events (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER fight_events_stamp BEFORE INSERT OR UPDATE ON public.fight_events
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.fight_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.fight_events FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.fight_events FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.fight_events FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.fight_events FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.fight_events TO authenticated;

CREATE TABLE public.fight_outcomes (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "run_id" uuid,
    "method" text,
    "winner_key" text,
    "loser_key" text,
    "event" text,
    "round" bigint,
    "created_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX fight_outcomes_pull ON public.fight_outcomes (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER fight_outcomes_stamp BEFORE INSERT OR UPDATE ON public.fight_outcomes
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.fight_outcomes ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.fight_outcomes FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.fight_outcomes FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.fight_outcomes FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.fight_outcomes FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.fight_outcomes TO authenticated;

CREATE TABLE public.fight_research (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "fight_label" text,
    "event" text,
    "fight_date" text,
    "summary_json" text,
    "sources_json" text,
    "provider" text,
    "model" text,
    "researched_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX fight_research_pull ON public.fight_research (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER fight_research_stamp BEFORE INSERT OR UPDATE ON public.fight_research
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.fight_research ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.fight_research FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.fight_research FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.fight_research FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.fight_research FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.fight_research TO authenticated;

CREATE TABLE public.wizard_research (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "topic" text,
    "result_json" text,
    "researched_at" text,
    "provider" text,
    "model" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX wizard_research_pull ON public.wizard_research (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER wizard_research_stamp BEFORE INSERT OR UPDATE ON public.wizard_research
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.wizard_research ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.wizard_research FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.wizard_research FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.wizard_research FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.wizard_research FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.wizard_research TO authenticated;

UPDATE public.schema_version SET version = 3 WHERE id = 1;
