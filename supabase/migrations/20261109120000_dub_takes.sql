-- Dub reuse Phase 5. Audio stays in the team Drive folder; rows carry its file ID.
-- video_id carries videos.sync_id. dub_takes.id is the portable content key,
-- distinct from the sync envelope UUID. Deletes use stamped tombstones.
-- Deploy with the client that understands schema 12; do not apply independently.

CREATE TABLE public.dub_takes (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "id" text,
    "video_id" uuid,
    "transcription_key" text,
    "row_start" double precision,
    "row_end" double precision,
    "language" text,
    "speaker_key" text,
    "text" text,
    "voice" text,
    "model" text,
    "settings_hash" text,
    "audio_file" text,
    "alignment_json" text,
    "edited" bigint,
    "created_at" text,
    "updated_at" text,
    "drive_file_id" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX dub_takes_pull ON public.dub_takes (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER dub_takes_stamp BEFORE INSERT OR UPDATE ON public.dub_takes
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.dub_takes ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.dub_takes FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.dub_takes FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.dub_takes FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.dub_takes FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.dub_takes TO authenticated;

CREATE TABLE public.dub_speaker_overrides (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "transcription_key" text,
    "row_start" double precision,
    "row_end" double precision,
    "language" text,
    "speaker_key" text,
    "updated_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX dub_speaker_overrides_pull ON public.dub_speaker_overrides (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER dub_speaker_overrides_stamp BEFORE INSERT OR UPDATE ON public.dub_speaker_overrides
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.dub_speaker_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.dub_speaker_overrides FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.dub_speaker_overrides FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.dub_speaker_overrides FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.dub_speaker_overrides FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.dub_speaker_overrides TO authenticated;

UPDATE public.schema_version SET version = 12 WHERE id = 1;
