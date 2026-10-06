#!/bin/zsh
# Team Sync admin helper: sign in with an emailed code, create a team, invite a
# member, list members, and launch the app so the team shows up in Settings › Team.
#
#   scripts/team_sync_admin.sh login <email>            # emails a code, prompts for it, stores a session
#   scripts/team_sync_admin.sh create-team "<name>"     # prints the new team id
#   scripts/team_sync_admin.sh invite <team-id> <email> # prints the invite code (7-day expiry)
#   scripts/team_sync_admin.sh members <team-id>
#   scripts/team_sync_admin.sh teams
#   scripts/team_sync_admin.sh launch [path/to/Clip Builder.app]
#   scripts/team_sync_admin.sh setup "<team name>" <invite email> [app]  # all of the above in one go
#
# The session is kept in $TEAM_SYNC_SESSION (default ~/.clipbuilder-team-sync-session.json),
# refreshed automatically. Attaching a profile is deliberately not automated: it
# runs through the app's confirmation sheet (Settings › Team › Attach This Profile…).
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://nekytkrbudqttttazhgo.supabase.co}"
SUPABASE_KEY="${SUPABASE_KEY:-sb_publishable_b4Q9R20qEWUCIiX1oxDtyg_Bk8QWIvE}"
SESSION="${TEAM_SYNC_SESSION:-$HOME/.clipbuilder-team-sync-session.json}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APP="$REPO_ROOT/build-debug/Build/Products/Debug/Clip Builder.app"

json() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=d
for k in sys.argv[1:]: v=v[k]
print(v if not isinstance(v,(dict,list)) else json.dumps(v))' "$@"; }

auth() { curl -sS -X POST "$SUPABASE_URL/auth/v1/$1" -H "apikey: $SUPABASE_KEY" -H "Content-Type: application/json" -d "$2"; }

login() {
    local email="$1"
    auth otp "{\"email\":\"$email\",\"create_user\":true}" > /dev/null
    echo "Code sent to $email."
    printf "Enter the code: "; read -r code
    local resp; resp="$(auth verify "{\"email\":\"$email\",\"token\":\"$code\",\"type\":\"email\"}")"
    if ! echo "$resp" | grep -q access_token; then echo "Sign-in failed: $resp" >&2; exit 1; fi
    echo "$resp" | python3 -I -c 'import json,sys,time; d=json.load(sys.stdin); d["expires_at"]=time.time()+d.get("expires_in",3600); print(json.dumps(d))' > "$SESSION"
    chmod 600 "$SESSION"
    echo "Signed in as $email."
}

token() {
    [[ -f "$SESSION" ]] || { echo "Not signed in. Run: $0 login <email>" >&2; exit 1; }
    local expires; expires="$(json expires_at < "$SESSION")"
    if python3 -I -c 'import sys,time; sys.exit(0 if float(sys.argv[1]) < time.time()+60 else 1)' "$expires"; then
        local refresh; refresh="$(json refresh_token < "$SESSION")"
        local resp; resp="$(curl -sS -X POST "$SUPABASE_URL/auth/v1/token?grant_type=refresh_token" -H "apikey: $SUPABASE_KEY" -H "Content-Type: application/json" -d "{\"refresh_token\":\"$refresh\"}")"
        echo "$resp" | grep -q access_token || { echo "Session expired. Run: $0 login <email>" >&2; exit 1; }
        echo "$resp" | python3 -I -c 'import json,sys,time; d=json.load(sys.stdin); d["expires_at"]=time.time()+d.get("expires_in",3600); print(json.dumps(d))' > "$SESSION"
    fi
    json access_token < "$SESSION"
}

rpc() { curl -sS -X POST "$SUPABASE_URL/rest/v1/rpc/$1" -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" -d "$2"; }

create_team() { rpc create_team "{\"name\":\"$1\"}" | tr -d '"'; echo; }
invite() { rpc create_invite "{\"team_id\":\"$1\",\"email\":\"$2\"}" | tr -d '"'; echo; }
members() { rpc team_members_with_email "{\"team_id\":\"$1\"}"; echo; }
teams() { curl -sS "$SUPABASE_URL/rest/v1/teams?select=id,name" -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $(token)"; echo; }

launch() {
    local app="${1:-$DEFAULT_APP}"
    [[ -d "$app" ]] || { echo "App not found: $app (build it with the run-app skill first)" >&2; exit 1; }
    open -a "$app"
    echo "Launched $app. Open Settings › Team: the team is listed; use Attach This Profile… to share the active profile."
}

setup() {
    local name="$1" email="$2" app="${3:-$DEFAULT_APP}"
    local team; team="$(create_team "$name")"
    echo "Team '$name': $team"
    local code; code="$(invite "$team" "$email")"
    echo "Invite for $email (expires in 7 days): $code"
    launch "$app"
}

case "${1:-}" in
    login) login "$2" ;;
    create-team) create_team "$2" ;;
    invite) invite "$2" "$3" ;;
    members) members "$2" ;;
    teams) teams ;;
    launch) launch "${2:-}" ;;
    setup) setup "$2" "$3" "${4:-}" ;;
    *) sed -n '2,13p' "$0"; exit 1 ;;
esac
