#!/bin/zsh
# Clip Builder guided setup.
#
# Installs everything Clip Builder needs (Homebrew, ffmpeg), optionally
# installs any of the Claude/Gemini/Codex CLIs (each can also be installed
# later from the app's Settings → AI), offers to log in to each installed
# provider, and walks the user through creating their first profile.
#
# Launched automatically by the .pkg installer's postinstall step, but safe
# to re-run at any time:
#   /Library/Application\ Support/ClipBuilder/Clip\ Builder\ Setup.command
set -u

# Homebrew lives outside the default PATH of a fresh Terminal.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; RESET=$'\e[0m'

step()  { echo; echo "${BOLD}==> $1${RESET}"; }
ok()    { echo "${GREEN}    ✓ $1${RESET}"; }
warn()  { echo "${YELLOW}    ! $1${RESET}"; }
fail()  { echo "${RED}    ✗ $1${RESET}"; }

# ask_yes_no "prompt" "default(y|n)" -> returns 0 for yes
ask_yes_no() {
    local prompt=$1 default=${2:-y} answer hint
    [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf "%s %s " "$prompt" "$hint"
        read -r answer || answer=""
        answer=${answer:l}
        [[ -z $answer ]] && answer=$default
        case $answer in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
        esac
    done
}

# ask "prompt" "default" -> echoes the answer (default when blank).
# The prompt goes to stderr so callers can capture the answer with $(ask ...).
ask() {
    local prompt=$1 default=${2:-} answer
    if [[ -n $default ]]; then
        printf "%s [%s]: " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
    fi
    read -r answer || answer=""
    [[ -z $answer ]] && answer=$default
    print -r -- "$answer"
}

json_escape() { print -r -- "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

echo "${BOLD}"
echo "╭──────────────────────────────────────────────╮"
echo "│         Clip Builder — Guided Setup          │"
echo "╰──────────────────────────────────────────────╯"
echo "${RESET}"
echo "This will install Clip Builder's dependencies and help you"
echo "configure the app. You may be asked for your Mac password."

# ---------------------------------------------------------------- Homebrew
step "Checking Homebrew"
if command -v brew >/dev/null 2>&1; then
    ok "Homebrew found: $(command -v brew)"
else
    warn "Homebrew not found — installing it now (this is the official installer)."
    echo "    You'll be asked for your password; press RETURN when prompted."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Pick up brew for the rest of this script.
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew installed"
    else
        fail "Homebrew installation failed. Install it from https://brew.sh and re-run this setup."
        exit 1
    fi
fi

# ------------------------------------------------------------ brew packages
step "Checking ffmpeg (video engine)"
if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg found: $(command -v ffmpeg)"
else
    echo "    Installing ffmpeg with Homebrew (this can take a few minutes)..."
    if brew install ffmpeg; then
        ok "ffmpeg installed"
    else
        fail "ffmpeg install failed — run 'brew install ffmpeg' manually, then re-run this setup."
        exit 1
    fi
fi

# ---------------------------------------------------------------- AI CLIs
# provider entries: key|binary|npm package|label
AI_PROVIDERS=(
    "claude|claude|@anthropic-ai/claude-code|Claude Code (Anthropic)"
    "gemini|gemini|@google/gemini-cli|Gemini CLI (Google)"
    "codex|codex|@openai/codex|Codex CLI (OpenAI)"
)

npm_install_global() {
    local pkg=$1
    local prefix
    prefix=$(npm prefix -g 2>/dev/null || echo "")
    if [[ -n $prefix && -w $prefix ]]; then
        npm install -g "$pkg"
    else
        warn "npm's global folder needs administrator rights."
        sudo npm install -g "$pkg"
    fi
}

# The CLIs are npm packages — install Node.js only once a provider is chosen.
ensure_node() {
    if command -v npm >/dev/null 2>&1; then
        return 0
    fi
    echo "    Installing Node.js with Homebrew (needed for the AI provider CLIs)..."
    if brew install node; then
        ok "Node.js installed"
        return 0
    fi
    fail "Node.js install failed — run 'brew install node' manually, then re-run this setup."
    return 1
}

step "AI provider CLIs (optional)"
echo "    Clip Builder can use any of these AI providers. Each one is optional —"
echo "    you can install any of them later from the app (Settings → AI) or by"
echo "    re-running this setup."
typeset -a INSTALLED_PROVIDERS
INSTALLED_PROVIDERS=()
for entry in "${AI_PROVIDERS[@]}"; do
    local_key=${entry%%|*}
    rest=${entry#*|};  bin=${rest%%|*}
    rest=${rest#*|};   pkg=${rest%%|*}
    label=${rest#*|}
    if command -v "$bin" >/dev/null 2>&1; then
        ok "$label already installed"
        INSTALLED_PROVIDERS+=("$entry")
        continue
    fi
    echo
    if ! ask_yes_no "    Install ${BOLD}$label${RESET} now?" y; then
        warn "Skipped — install later from the app (Settings → AI)."
        continue
    fi
    if ! ensure_node; then
        warn "Skipping $label — Node.js is required for it."
        continue
    fi
    echo "    Installing $label..."
    if npm_install_global "$pkg"; then
        ok "$label installed"
        INSTALLED_PROVIDERS+=("$entry")
    else
        fail "$label failed to install — you can retry later with: npm install -g $pkg"
    fi
done
if (( ${#INSTALLED_PROVIDERS} == 0 )); then
    warn "No AI providers installed — Clip Builder's AI features will be off"
    warn "until you add one from Settings → AI in the app."
fi

# -------------------------------------------------------------- CLI logins
if (( ${#INSTALLED_PROVIDERS} > 0 )); then
step "AI provider sign-in"
echo "    Each provider needs a one-time sign-in before Clip Builder can use it."
echo "    You can do it now, or later by running the command shown."
for entry in "${INSTALLED_PROVIDERS[@]}"; do
    local_key=${entry%%|*}
    rest=${entry#*|};  bin=${rest%%|*}
    rest=${rest#*|};   pkg=${rest%%|*}
    label=${rest#*|}
    echo
    if ask_yes_no "    Sign in to ${BOLD}$label${RESET} now?" y; then
        case $local_key in
            claude)
                echo "    Opening Claude Code — complete the login, then type /exit to continue."
                "$bin" || true
                ;;
            gemini)
                echo "    Opening Gemini CLI — choose a login method, then type /quit to continue."
                "$bin" || true
                ;;
            codex)
                echo "    Starting Codex login (a browser window may open)..."
                "$bin" login || true
                ;;
        esac
        ok "Done with $label (Clip Builder's Settings → AI shows its status)"
    else
        case $local_key in
            codex) warn "Later: run '$bin login' in Terminal to sign in." ;;
            *)     warn "Later: run '$bin' in Terminal and complete the login." ;;
        esac
    fi
done
fi

# ----------------------------------------------------------- first profile
PROFILES_DIR="$HOME/Documents/ClipBuilder"
DATA_DIR="$PROFILES_DIR/data"

sanitize_profile_name() {
    # Mirrors the app's ProfileStore.sanitize: keep A-Za-z0-9 _ - . and space.
    local trimmed
    trimmed=$(print -r -- "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    local safe
    safe=$(print -r -- "$trimmed" | sed 's/[^A-Za-z0-9_. -]/_/g')
    [[ -z $safe ]] && safe="default"
    print -r -- "$safe"
}

create_profile() {
    echo
    echo "    A profile holds your brand info, folders, and caption style."
    local name brand domain instagram tiktok youtube input_dir output_dir
    while true; do
        name=$(ask "    Profile name" "My Brand")
        name=$(sanitize_profile_name "$name")
        if [[ -f "$PROFILES_DIR/$name.json" ]]; then
            warn "A profile named '$name' already exists — pick another name."
        else
            break
        fi
    done
    brand=$(ask "    Brand name shown in captions/exports" "$name")
    domain=$(ask "    Content niche (e.g. MMA, cooking, gaming — guides the AI)" "")
    instagram=$(ask "    Instagram handle (optional)" "")
    tiktok=$(ask "    TikTok handle (optional)" "")
    youtube=$(ask "    YouTube handle (optional)" "")
    input_dir=$(ask "    Folder for source videos" "~/Documents/ClipBuilder/$name/Input")
    output_dir=$(ask "    Folder for rendered clips" "~/Documents/ClipBuilder/$name/Output")

    mkdir -p "$PROFILES_DIR" "$DATA_DIR"
    cat > "$PROFILES_DIR/$name.json" <<PROFILE
{
  "brand_name" : "$(json_escape "$brand")",
  "captions" : {
    "bg_color" : "#000000",
    "bg_on" : false,
    "color" : "#ffffff",
    "font" : "sans",
    "position" : "bottom"
  },
  "content_domain" : "$(json_escape "$domain")",
  "output_folder" : "$(json_escape "$output_dir")",
  "profile_name" : "$(json_escape "$name")",
  "socials" : {
    "instagram" : { "cookies" : "", "handle" : "$(json_escape "$instagram")", "url" : "" },
    "tiktok" : { "cookies" : "", "handle" : "$(json_escape "$tiktok")", "url" : "" },
    "youtube" : { "cookies" : "", "handle" : "$(json_escape "$youtube")", "url" : "" }
  },
  "source_folder" : "$(json_escape "$input_dir")",
  "tag_schema" : {}
}
PROFILE

    # Create the Input/Output folders so the app's folder watcher has
    # something to watch on first launch.
    mkdir -p "${input_dir/#\~/$HOME}" "${output_dir/#\~/$HOME}"

    # Make it the active profile.
    printf '{"name":"%s"}' "$(json_escape "$name")" > "$DATA_DIR/active_profile.json"

    ok "Profile '$name' created and set as active"
    echo "      Config:  $PROFILES_DIR/$name.json"
    echo "      Input:   $input_dir"
    echo "      Output:  $output_dir"
}

step "First profile"
existing_profiles=("$PROFILES_DIR"/*.json(N))
if (( ${#existing_profiles} > 0 )); then
    ok "Found ${#existing_profiles} existing profile(s) in $PROFILES_DIR"
    if ask_yes_no "    Create another profile anyway?" n; then
        create_profile
    fi
else
    if ask_yes_no "    Create your first profile now?" y; then
        create_profile
    else
        warn "Skipped — the app creates a 'Default' profile on first launch;"
        warn "you can customize it in Settings → Profile."
    fi
fi

# ------------------------------------------------------------------ finish
step "Setup complete"
command -v ffmpeg >/dev/null 2>&1 && ok "ffmpeg ready" || warn "ffmpeg missing"
for entry in "${AI_PROVIDERS[@]}"; do
    bin=$(print -r -- "$entry" | cut -d'|' -f2)
    label=$(print -r -- "$entry" | cut -d'|' -f4)
    command -v "$bin" >/dev/null 2>&1 && ok "$label ready" || warn "$label not installed (optional — add it from Settings → AI)"
done
echo
echo "    In the app, check Settings → General (ffmpeg status) and"
echo "    Settings → AI (provider status and task routing)."
echo

if [[ -d "/Applications/Clip Builder.app" ]]; then
    if ask_yes_no "Launch Clip Builder now?" y; then
        open -a "Clip Builder"
    fi
else
    warn "/Applications/Clip Builder.app not found — install the app first."
fi
echo
echo "You can close this window."
