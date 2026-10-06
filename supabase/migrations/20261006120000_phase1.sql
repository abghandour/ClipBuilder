-- Phase 1: additive mirrors. Apply only after review; never from the app.
-- All members can tombstone rows. Retain tombstones for at least 90 days;
-- there is deliberately no client DELETE grant or automatic purge.
ALTER TABLE public.team_members ADD COLUMN role text NOT NULL DEFAULT 'member'
    CHECK (role IN ('owner', 'member'));
REVOKE INSERT, UPDATE, DELETE ON public.teams, public.team_members, public.team_invites FROM authenticated;

CREATE TABLE public.profile_documents (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "document_json" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz,
    CHECK (sync_id = profile_id)
);
CREATE INDEX profile_documents_pull ON public.profile_documents (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER profile_documents_stamp BEFORE INSERT OR UPDATE ON public.profile_documents
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.profile_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.profile_documents FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.profile_documents FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.profile_documents FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.profile_documents FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.profile_documents TO authenticated;

CREATE TABLE public.people (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "key" text,
    "name" text,
    "descriptor" text,
    "created_at" text,
    "category" text,
    "hidden" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX people_pull ON public.people (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER people_stamp BEFORE INSERT OR UPDATE ON public.people
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.people ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.people FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.people FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.people FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.people FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.people TO authenticated;

CREATE TABLE public.text_overlay_presets (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "name" text,
    "data_json" text,
    "created_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX text_overlay_presets_pull ON public.text_overlay_presets (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER text_overlay_presets_stamp BEFORE INSERT OR UPDATE ON public.text_overlay_presets
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.text_overlay_presets ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.text_overlay_presets FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.text_overlay_presets FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.text_overlay_presets FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.text_overlay_presets FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.text_overlay_presets TO authenticated;

CREATE TABLE public.library_asset_metadata (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "kind" text,
    "is_broll" bigint,
    "subjects_json" text,
    "tags_json" text,
    "provider" text,
    "model" text,
    "analyzed_at" text,
    "display_name" text,
    "placements_json" text,
    "technique" text,
    "asset_id" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX library_asset_metadata_pull ON public.library_asset_metadata (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER library_asset_metadata_stamp BEFORE INSERT OR UPDATE ON public.library_asset_metadata
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.library_asset_metadata ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.library_asset_metadata FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.library_asset_metadata FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.library_asset_metadata FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.library_asset_metadata FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.library_asset_metadata TO authenticated;

CREATE TABLE public.ig_accounts (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "username" text,
    "kind" text,
    "display_name" text,
    "ig_user_id" text,
    "followers" bigint,
    "last_fetched_at" text,
    "added_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_accounts_pull ON public.ig_accounts (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_accounts_stamp BEFORE INSERT OR UPDATE ON public.ig_accounts
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_accounts FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_accounts FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_accounts FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_accounts FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_accounts TO authenticated;

CREATE TABLE public.ig_media (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "media_id" text,
    "media_type" text,
    "caption" text,
    "permalink" text,
    "posted_at" text,
    "duration" double precision,
    "stats_json" text,
    "source" text,
    "fetched_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_media_pull ON public.ig_media (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_media_stamp BEFORE INSERT OR UPDATE ON public.ig_media
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_media ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_media FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_media FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_media FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_media FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_media TO authenticated;

CREATE TABLE public.ig_report_media (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "media_id" text,
    "shortcode" text,
    "media_type" text,
    "media_product_type" text,
    "caption" text,
    "caption_truncated" bigint,
    "permalink" text,
    "posted_at" text,
    "like_count" bigint,
    "comments_count" bigint,
    "thumbnail_url" text,
    "source" text,
    "fetched_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_report_media_pull ON public.ig_report_media (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_report_media_stamp BEFORE INSERT OR UPDATE ON public.ig_report_media
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_report_media ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_report_media FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_report_media FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_report_media FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_report_media FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_report_media TO authenticated;

CREATE TABLE public.taste_studies (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "media_id" uuid,
    "category_key" text,
    "studied_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX taste_studies_pull ON public.taste_studies (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER taste_studies_stamp BEFORE INSERT OR UPDATE ON public.taste_studies
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.taste_studies ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.taste_studies FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.taste_studies FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.taste_studies FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.taste_studies FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.taste_studies TO authenticated;

CREATE TABLE public.ig_templates (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "media_id" uuid,
    "template_json" text,
    "provider" text,
    "model" text,
    "analyzed_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_templates_pull ON public.ig_templates (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_templates_stamp BEFORE INSERT OR UPDATE ON public.ig_templates
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_templates FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_templates FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_templates FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_templates FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_templates TO authenticated;

CREATE TABLE public.ig_account_snapshots (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "snapshot_date" text,
    "followers_count" bigint,
    "follows_count" bigint,
    "media_count" bigint,
    "source" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_account_snapshots_pull ON public.ig_account_snapshots (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_account_snapshots_stamp BEFORE INSERT OR UPDATE ON public.ig_account_snapshots
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_account_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_account_snapshots FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_account_snapshots FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_account_snapshots FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_account_snapshots FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_account_snapshots TO authenticated;

CREATE TABLE public.ig_media_insight_snapshots (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "report_media_id" uuid,
    "metric" text,
    "value" double precision,
    "fetched_at" text,
    "source" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_media_insight_snapshots_pull ON public.ig_media_insight_snapshots (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_media_insight_snapshots_stamp BEFORE INSERT OR UPDATE ON public.ig_media_insight_snapshots
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_media_insight_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_media_insight_snapshots FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_media_insight_snapshots FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_media_insight_snapshots FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_media_insight_snapshots FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_media_insight_snapshots TO authenticated;

CREATE TABLE public.ig_account_insights (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "metric" text,
    "period" text,
    "breakdown_dimension" text,
    "breakdown_value" text,
    "value" double precision,
    "end_time" text,
    "source" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_account_insights_pull ON public.ig_account_insights (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_account_insights_stamp BEFORE INSERT OR UPDATE ON public.ig_account_insights
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_account_insights ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_account_insights FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_account_insights FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_account_insights FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_account_insights FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_account_insights TO authenticated;

CREATE TABLE public.ig_audience_demographics (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "metric" text,
    "dimension" text,
    "dimension_value" text,
    "timeframe" text,
    "value" bigint,
    "fetched_date" text,
    "source" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_audience_demographics_pull ON public.ig_audience_demographics (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_audience_demographics_stamp BEFORE INSERT OR UPDATE ON public.ig_audience_demographics
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_audience_demographics ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_audience_demographics FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_audience_demographics FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_audience_demographics FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_audience_demographics FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_audience_demographics TO authenticated;

CREATE TABLE public.ig_comments (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "id" text,
    "account_id" uuid,
    "report_media_id" uuid,
    "parent_comment_id" text,
    "username" text,
    "from_id" text,
    "text" text,
    "like_count" bigint,
    "hidden" bigint,
    "timestamp" text,
    "ref_timestamp" text,
    "fetched_at" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_comments_pull ON public.ig_comments (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_comments_stamp BEFORE INSERT OR UPDATE ON public.ig_comments
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_comments ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_comments FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_comments FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_comments FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_comments FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_comments TO authenticated;

CREATE TABLE public.ig_commenter_rankings_import (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "period_key" text,
    "as_of" text,
    "username" text,
    "rank" bigint,
    "score" bigint,
    "early" bigint,
    "text_comments" bigint,
    "emoji_comments" bigint,
    "text_replies" bigint,
    "emoji_replies" bigint,
    "total" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_commenter_rankings_import_pull ON public.ig_commenter_rankings_import (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_commenter_rankings_import_stamp BEFORE INSERT OR UPDATE ON public.ig_commenter_rankings_import
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_commenter_rankings_import ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_commenter_rankings_import FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_commenter_rankings_import FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_commenter_rankings_import FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_commenter_rankings_import FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_commenter_rankings_import TO authenticated;

CREATE TABLE public.ig_commenter_activity_import (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "period_key" text,
    "as_of" text,
    "username" text,
    "comments" bigint,
    "replies" bigint,
    "total" bigint,
    "top_posts_json" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_commenter_activity_import_pull ON public.ig_commenter_activity_import (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_commenter_activity_import_stamp BEFORE INSERT OR UPDATE ON public.ig_commenter_activity_import
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_commenter_activity_import ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_commenter_activity_import FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_commenter_activity_import FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_commenter_activity_import FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_commenter_activity_import FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_commenter_activity_import TO authenticated;

CREATE TABLE public.ig_comment_heatmap_import (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "window_end" text,
    "dow" bigint,
    "hour" bigint,
    "count" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_comment_heatmap_import_pull ON public.ig_comment_heatmap_import (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_comment_heatmap_import_stamp BEFORE INSERT OR UPDATE ON public.ig_comment_heatmap_import
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_comment_heatmap_import ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_comment_heatmap_import FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_comment_heatmap_import FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_comment_heatmap_import FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_comment_heatmap_import FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_comment_heatmap_import TO authenticated;

CREATE TABLE public.ig_reel_analysis_import (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "report_media_id" uuid,
    "analysis_date" text,
    "score" bigint,
    "tier" text,
    "good_json" text,
    "bad_json" text,
    "top_tip" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_reel_analysis_import_pull ON public.ig_reel_analysis_import (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_reel_analysis_import_stamp BEFORE INSERT OR UPDATE ON public.ig_reel_analysis_import
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_reel_analysis_import ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_reel_analysis_import FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_reel_analysis_import FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_reel_analysis_import FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_reel_analysis_import FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_reel_analysis_import TO authenticated;

CREATE TABLE public.ig_ignored_accounts (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "username" text,
    "reason" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_ignored_accounts_pull ON public.ig_ignored_accounts (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_ignored_accounts_stamp BEFORE INSERT OR UPDATE ON public.ig_ignored_accounts
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_ignored_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_ignored_accounts FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_ignored_accounts FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_ignored_accounts FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_ignored_accounts FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_ignored_accounts TO authenticated;

CREATE TABLE public.ig_report_sync_state (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "account_id" uuid,
    "key" text,
    "value" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX ig_report_sync_state_pull ON public.ig_report_sync_state (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER ig_report_sync_state_stamp BEFORE INSERT OR UPDATE ON public.ig_report_sync_state
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.ig_report_sync_state ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.ig_report_sync_state FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.ig_report_sync_state FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.ig_report_sync_state FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.ig_report_sync_state FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ig_report_sync_state TO authenticated;

CREATE TABLE public.reel_traits (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_kind" text,
    "video_id" text,
    "version" bigint,
    "traits_json" text,
    "computed_at" text,
    "reference" bigint,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX reel_traits_pull ON public.reel_traits (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER reel_traits_stamp BEFORE INSERT OR UPDATE ON public.reel_traits
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.reel_traits ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.reel_traits FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.reel_traits FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.reel_traits FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.reel_traits FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.reel_traits TO authenticated;

CREATE TABLE public.reel_outcomes (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    "video_id" uuid,
    "account_id" uuid,
    "traits_version" bigint,
    "outcome_json" text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX reel_outcomes_pull ON public.reel_outcomes (team_id, profile_id, server_updated_at, sync_id);
CREATE TRIGGER reel_outcomes_stamp BEFORE INSERT OR UPDATE ON public.reel_outcomes
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();
ALTER TABLE public.reel_outcomes ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_read ON public.reel_outcomes FOR SELECT TO authenticated USING (public.is_team_member(team_id));
CREATE POLICY member_insert ON public.reel_outcomes FOR INSERT TO authenticated WITH CHECK (public.is_team_member(team_id));
CREATE POLICY member_update ON public.reel_outcomes FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
REVOKE ALL ON public.reel_outcomes FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.reel_outcomes TO authenticated;

CREATE FUNCTION public.create_team(name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result uuid;
BEGIN
    IF auth.uid() IS NULL OR nullif(btrim(name), '') IS NULL THEN
        RAISE EXCEPTION 'Sign in and provide a team name';
    END IF;
    INSERT INTO public.teams(name) VALUES (btrim(name)) RETURNING id INTO result;
    INSERT INTO public.team_members(team_id, user_id, role) VALUES (result, auth.uid(), 'owner');
    RETURN result;
END;
$$;
CREATE FUNCTION public.create_invite(team_id uuid, email text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result uuid;
BEGIN
    IF NOT public.is_team_member(team_id) OR nullif(btrim(email), '') IS NULL THEN
        RAISE EXCEPTION 'Team membership and an email are required';
    END IF;
    INSERT INTO public.team_invites(team_id, email)
        VALUES (team_id, lower(btrim(email))) RETURNING code INTO result;
    RETURN result;
END;
$$;
CREATE FUNCTION public.redeem_invite(code uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE invitation public.team_invites; member_email text;
BEGIN
    SELECT u.email INTO member_email FROM auth.users u
        WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;
    SELECT i.* INTO invitation FROM public.team_invites i
        WHERE i.code = redeem_invite.code FOR UPDATE;
    IF invitation.id IS NULL OR invitation.expires_at <= now()
       OR member_email IS NULL OR lower(member_email) <> lower(invitation.email) THEN
        RAISE EXCEPTION 'Invite is invalid, expired, or belongs to another email';
    END IF;
    INSERT INTO public.team_members(team_id, user_id) VALUES (invitation.team_id, auth.uid())
        ON CONFLICT DO NOTHING;
    DELETE FROM public.team_invites WHERE id = invitation.id;
    RETURN invitation.team_id;
END;
$$;
CREATE FUNCTION public.team_members_with_email(team_id uuid)
RETURNS TABLE(user_id uuid, email text, role text, joined_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NOT public.is_team_member(team_id) THEN RAISE EXCEPTION 'Team membership required'; END IF;
    RETURN QUERY SELECT m.user_id, u.email::text, m.role, m.joined_at
        FROM public.team_members m JOIN auth.users u ON u.id = m.user_id
        WHERE m.team_id = team_members_with_email.team_id ORDER BY m.joined_at;
END;
$$;
REVOKE ALL ON FUNCTION public.create_team(text), public.create_invite(uuid, text),
    public.redeem_invite(uuid), public.team_members_with_email(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_team(text), public.create_invite(uuid, text),
    public.redeem_invite(uuid), public.team_members_with_email(uuid) TO authenticated;
UPDATE public.schema_version SET version = 2 WHERE id = 1;
