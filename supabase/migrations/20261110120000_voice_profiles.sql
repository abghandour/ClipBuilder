-- Voice profile sync. One row per person per video: the voice fingerprint that
-- file taught (192 numbers from the bundled speaker model, as JSON text).
-- video_id carries videos.sync_id; person_key is the portable people.key.
-- Deletes use stamped tombstones.
-- Deploy with the client that understands schema 13; do not apply independently.

CREATE TABLE public.voice_profiles (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "person_key" text,
    "video_id" uuid,
    "vector_json" text,
    "windows" bigint,
    "correction_windows" bigint,
    "updated_at" text,
    "transcription_key" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX voice_profiles_pull ON public.voice_profiles (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER voice_profiles_stamp BEFORE INSERT OR UPDATE ON public.voice_profiles
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.voice_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.voice_profiles FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.voice_profiles FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.voice_profiles FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.voice_profiles FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.voice_profiles TO authenticated;

UPDATE public.schema_version SET version = 13 WHERE id = 1;
