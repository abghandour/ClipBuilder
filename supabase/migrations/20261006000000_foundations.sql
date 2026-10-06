-- Supabase CLI wraps each migration in its own transaction; no BEGIN/COMMIT here.
-- Phase 0. Apply once with the migration owner. Future migrations are additive.
-- Team creation / invitation redemption belongs to Phase 1; bootstrap membership
-- with the service role for now. Never distribute that key to the app.
CREATE TABLE public.teams (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.team_members (
    team_id uuid NOT NULL REFERENCES public.teams(id),
    user_id uuid NOT NULL REFERENCES auth.users(id),
    joined_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, user_id)
);
CREATE TABLE public.team_invites (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL REFERENCES public.teams(id),
    email text NOT NULL,
    code uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    expires_at timestamptz NOT NULL DEFAULT now() + interval '7 days',
    created_by uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id)
);
CREATE TABLE public.schema_version (
    id integer PRIMARY KEY CHECK (id = 1),
    version integer NOT NULL,
    last_stamp timestamptz NOT NULL DEFAULT '-infinity'
);
INSERT INTO public.schema_version (id, version) VALUES (1, 1);
CREATE TABLE public.wizard_lessons (
    sync_id uuid PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES public.teams(id),
    profile_id uuid NOT NULL,
    text text NOT NULL DEFAULT '',
    pinned integer NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
    evidence text NOT NULL DEFAULT '',
    provider text,
    model text,
    learned_id text,
    created_at text,
    updated_at text,
    server_updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz
);
CREATE INDEX wizard_lessons_pull ON public.wizard_lessons
    (team_id, profile_id, server_updated_at, sync_id);

-- SECURITY DEFINER avoids recursive team_members RLS; fixed search_path prevents
-- object shadowing. No caller may choose whose membership is checked.
CREATE FUNCTION public.is_team_member(wanted_team uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT EXISTS (SELECT 1 FROM public.team_members
                   WHERE team_id = wanted_team AND user_id = auth.uid());
$$;
REVOKE ALL ON FUNCTION public.is_team_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_team_member(uuid) TO authenticated;

-- Serialize stamps through one locked row: a transaction cannot commit an older
-- stamp after a pull cursor has passed it. Client clocks never order changes.
CREATE FUNCTION public.stamp_sync_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.team_id <> OLD.team_id OR
        NEW.profile_id <> OLD.profile_id OR NEW.sync_id <> OLD.sync_id) THEN
        RAISE EXCEPTION 'Sync identity and scope are immutable';
    END IF;
    UPDATE public.schema_version
       SET last_stamp = greatest(clock_timestamp(), last_stamp + interval '1 microsecond')
     WHERE id = 1 RETURNING last_stamp INTO NEW.server_updated_at;
    NEW.updated_by := auth.uid();
    IF NEW.deleted_at IS NOT NULL THEN
        NEW.deleted_at := NEW.server_updated_at;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.stamp_sync_row() FROM PUBLIC;
CREATE TRIGGER wizard_lessons_stamp BEFORE INSERT OR UPDATE ON public.wizard_lessons
    FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_row();

ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schema_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wizard_lessons ENABLE ROW LEVEL SECURITY;
CREATE POLICY team_access ON public.teams TO authenticated
    USING (public.is_team_member(id)) WITH CHECK (public.is_team_member(id));
CREATE POLICY member_access ON public.team_members TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
CREATE POLICY invite_access ON public.team_invites TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
CREATE POLICY lesson_read ON public.wizard_lessons FOR SELECT TO authenticated
    USING (public.is_team_member(team_id));
CREATE POLICY lesson_insert ON public.wizard_lessons FOR INSERT TO authenticated
    WITH CHECK (public.is_team_member(team_id));
CREATE POLICY lesson_update ON public.wizard_lessons FOR UPDATE TO authenticated
    USING (public.is_team_member(team_id)) WITH CHECK (public.is_team_member(team_id));
-- No client DELETE permission/policy: deletes must remain visible as tombstones.
-- Keep tombstones for at least 90 days. No purge is scheduled in Phase 0.
CREATE POLICY version_read ON public.schema_version FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.teams, public.team_members, public.team_invites,
    public.schema_version, public.wizard_lessons FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.teams, public.team_members,
    public.team_invites TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.wizard_lessons TO authenticated;
GRANT SELECT (id, version) ON public.schema_version TO authenticated;
