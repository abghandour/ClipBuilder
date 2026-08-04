#!/bin/zsh
# Clip Builder guided setup.
#
# Installs everything Clip Builder needs (ffmpeg, ffprobe, yt-dlp) as
# standalone binaries — no Homebrew and no Xcode Command Line Tools —
# optionally installs any of the Claude/Gemini/Codex CLIs (each can also be
# installed later by re-running this setup), offers to log in to each
# installed provider, and walks the user through creating their first
# profile.
#
# Launched automatically by the .pkg installer's postinstall step, but safe
# to re-run at any time:
#   /Library/Application\ Support/ClipBuilder/Clip\ Builder\ Setup.command
set -u

# Tools install into the app's managed bin folder, which the app searches
# before the system prefixes (ProcessRunner.managedBinDirectory). Existing
# installs — Homebrew or otherwise — are detected and left alone.
SUPPORT_DIR="$HOME/Library/Application Support/ClipBuilder"
BIN_DIR="$SUPPORT_DIR/bin"
NODE_DIR="$SUPPORT_DIR/node"   # private Node.js, only for npm-only CLIs
NPM_PREFIX="$SUPPORT_DIR/npm"
export PATH="$BIN_DIR:$NPM_PREFIX/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

case "$(uname -m)" in
    arm64)
        FFMPEG_BASE="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release"
        CODEX_ASSET="codex-aarch64-apple-darwin"
        NODE_ARCH="darwin-arm64"
        ;;
    *)
        FFMPEG_BASE="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release"
        CODEX_ASSET="codex-x86_64-apple-darwin"
        NODE_ARCH="darwin-x64"
        ;;
esac
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"

WORK_DIR=$(mktemp -d -t clipbuilder-setup)
trap 'rm -rf "$WORK_DIR"' EXIT

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

# download "url" "dest" — some hosts 404 on a subset of their load-balanced
# backends, so retry; each curl run opens a fresh connection, which is what
# gets the retry onto a different backend.
download() {
    local url=$1 dest=$2 attempt
    for attempt in 1 2 3; do
        (( attempt > 1 )) && sleep 2
        curl -fL --connect-timeout 15 --progress-bar -o "$dest" "$url" && return 0
    done
    return 1
}

# Downloaded executables won't pass Gatekeeper if quarantined (curl doesn't
# quarantine, but be defensive), and zip extraction can drop the exec bit.
finalize_binary() {
    chmod 755 "$1"
    xattr -d com.apple.quarantine "$1" 2>/dev/null || true
}

echo "${BOLD}"
echo "╭──────────────────────────────────────────────╮"
echo "│         Clip Builder — Guided Setup          │"
echo "╰──────────────────────────────────────────────╯"
echo "${RESET}"
echo "This will install Clip Builder's dependencies and help you"
echo "configure the app. Everything installs into your user folder —"
echo "no Homebrew, Xcode tools, or administrator password required."

mkdir -p "$BIN_DIR"

# ------------------------------------------------------------- media tools
# ffmpeg + ffprobe come as per-architecture single-binary zips; yt-dlp is
# the official self-contained macOS build (universal binary).
install_media_tool() {
    local tool=$1
    if [[ $tool == yt-dlp ]]; then
        download "$YTDLP_URL" "$WORK_DIR/yt-dlp" || return 1
        mv "$WORK_DIR/yt-dlp" "$BIN_DIR/yt-dlp"
    else
        download "$FFMPEG_BASE/$tool.zip" "$WORK_DIR/$tool.zip" || return 1
        /usr/bin/ditto -x -k "$WORK_DIR/$tool.zip" "$BIN_DIR" || return 1
    fi
    finalize_binary "$BIN_DIR/$tool"
}

media_tool_label() {
    case $1 in
        ffmpeg)  echo "ffmpeg (video engine)" ;;
        ffprobe) echo "ffprobe (video analysis)" ;;
        yt-dlp)  echo "yt-dlp (video downloads)" ;;
    esac
}

for tool in ffmpeg ffprobe yt-dlp; do
    step "Checking $(media_tool_label "$tool")"
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool found: $(command -v "$tool")"
        continue
    fi
    echo "    Downloading $tool..."
    if install_media_tool "$tool"; then
        ok "$tool installed into $BIN_DIR"
    else
        fail "$tool download failed — check your internet connection and re-run this setup."
        exit 1
    fi
done

# ---------------------------------------------------------------- AI CLIs
# provider entries: key|binary|label
AI_PROVIDERS=(
    "claude|claude|Claude Code (Anthropic)"
    "gemini|gemini|Gemini CLI (Google)"
    "codex|codex|Codex CLI (OpenAI)"
)

# Gemini's CLI only ships as an npm package. Prefer an existing npm; without
# one, download the official standalone Node.js LTS build into the app's
# support folder — private to Clip Builder, no Homebrew, no sudo.
ensure_node() {
    if command -v npm >/dev/null 2>&1; then
        return 0
    fi
    if [[ -x "$NODE_DIR/bin/npm" ]]; then
        export PATH="$NODE_DIR/bin:$PATH"
        return 0
    fi
    echo "    Downloading Node.js (needed for this CLI)..."
    local version
    version=$(curl -fsSL https://nodejs.org/dist/index.json \
        | grep -m1 '"lts":"' | sed -E 's/.*"version":"([^"]+)".*/\1/')
    if [[ -z ${version:-} ]]; then
        fail "Could not determine the latest Node.js LTS version — check your internet connection."
        return 1
    fi
    download "https://nodejs.org/dist/$version/node-$version-$NODE_ARCH.tar.gz" "$WORK_DIR/node.tar.gz" \
        || { fail "Node.js download failed — check your internet connection and re-run this setup."; return 1 }
    rm -rf "$NODE_DIR"
    mkdir -p "$NODE_DIR"
    /usr/bin/tar -xzf "$WORK_DIR/node.tar.gz" -C "$NODE_DIR" --strip-components 1 \
        || { fail "Could not unpack Node.js."; return 1 }
    export PATH="$NODE_DIR/bin:$PATH"
    ok "Node.js $version installed (private to Clip Builder)"
}

# Install an npm CLI. With the private Node the package lands in the app's
# support folder and gets a wrapper in BIN_DIR, so the app can run it without
# node on the system PATH; with the user's own npm it goes wherever their
# global prefix points (may need sudo, as before).
install_npm_cli() {
    local pkg=$1 bin=$2
    ensure_node || return 1
    if [[ "$(command -v npm)" == "$NODE_DIR/bin/npm" ]]; then
        # Private cache too — a user's ~/.npm can hold root-owned files from
        # past `sudo npm install -g` runs, which break installs with EACCES.
        NPM_CONFIG_PREFIX="$NPM_PREFIX" NPM_CONFIG_CACHE="$SUPPORT_DIR/npm-cache" \
            npm install -g "$pkg" || return 1
        cat > "$BIN_DIR/$bin" <<WRAPPER
#!/bin/zsh
export PATH="$NODE_DIR/bin:\$PATH"
exec "$NPM_PREFIX/bin/$bin" "\$@"
WRAPPER
        finalize_binary "$BIN_DIR/$bin"
    else
        local prefix
        prefix=$(npm prefix -g 2>/dev/null || echo "")
        if [[ -n $prefix && -w $prefix ]]; then
            npm install -g "$pkg" || return 1
        else
            warn "npm's global folder needs administrator rights."
            sudo npm install -g "$pkg" || return 1
        fi
    fi
}

install_provider() {
    case $1 in
        claude)
            # Official native installer — a self-contained binary in
            # ~/.local/bin, added to the shell PATH by the installer.
            /bin/bash -c "$(curl -fsSL https://claude.ai/install.sh)" ;;
        codex)
            download "https://github.com/openai/codex/releases/latest/download/$CODEX_ASSET.tar.gz" \
                "$WORK_DIR/codex.tar.gz" || return 1
            /usr/bin/tar -xzf "$WORK_DIR/codex.tar.gz" -C "$WORK_DIR" || return 1
            mv "$WORK_DIR/$CODEX_ASSET" "$BIN_DIR/codex"
            finalize_binary "$BIN_DIR/codex" ;;
        gemini)
            install_npm_cli "@google/gemini-cli" "gemini" ;;
    esac
}

retry_hint() {
    case $1 in
        claude) echo "curl -fsSL https://claude.ai/install.sh | bash" ;;
        *)      echo "re-running this setup" ;;
    esac
}

step "AI provider CLIs (optional)"
echo "    Clip Builder can use any of these AI providers. Each one is optional —"
echo "    you can install any of them later by re-running this setup."
typeset -a INSTALLED_PROVIDERS
INSTALLED_PROVIDERS=()
for entry in "${AI_PROVIDERS[@]}"; do
    local_key=${entry%%|*}
    rest=${entry#*|};  bin=${rest%%|*}
    label=${rest#*|}
    if command -v "$bin" >/dev/null 2>&1; then
        ok "$label already installed"
        INSTALLED_PROVIDERS+=("$entry")
        continue
    fi
    echo
    if ! ask_yes_no "    Install ${BOLD}$label${RESET} now?" y; then
        warn "Skipped — install later by re-running this setup."
        continue
    fi
    echo "    Installing $label..."
    rehash
    if install_provider "$local_key" && rehash && command -v "$bin" >/dev/null 2>&1; then
        ok "$label installed"
        INSTALLED_PROVIDERS+=("$entry")
    else
        fail "$label failed to install — you can retry later with: $(retry_hint "$local_key")"
    fi
done
if (( ${#INSTALLED_PROVIDERS} == 0 )); then
    warn "No AI providers installed — Clip Builder's AI features will be off"
    warn "until you re-run this setup and add one."
fi

# -------------------------------------------------------------- CLI logins
# Best-effort check for an existing sign-in so re-runs don't nag. Each CLI
# leaves a credential artifact behind after login: Claude Code a Keychain
# entry (a JSON file on other setups), Gemini and Codex a file in $HOME.
is_signed_in() {
    case $1 in
        claude)
            security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 \
                || [[ -f "$HOME/.claude/.credentials.json" ]] ;;
        gemini)
            [[ -f "$HOME/.gemini/oauth_creds.json" || -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ]] ;;
        codex)
            [[ -f "$HOME/.codex/auth.json" ]] ;;
        *)  return 1 ;;
    esac
}

if (( ${#INSTALLED_PROVIDERS} > 0 )); then
step "AI provider sign-in"
echo "    Each provider needs a one-time sign-in before Clip Builder can use it."
echo "    You can do it now, or later by re-running this setup."
for entry in "${INSTALLED_PROVIDERS[@]}"; do
    local_key=${entry%%|*}
    rest=${entry#*|};  bin=${rest%%|*}
    label=${rest#*|}
    if is_signed_in "$local_key"; then
        ok "$label — already signed in"
        continue
    fi
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
        warn "Later: re-run this setup and pick 'Sign in' for $label."
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
for tool in ffmpeg ffprobe yt-dlp; do
    command -v "$tool" >/dev/null 2>&1 && ok "$tool ready" || warn "$tool missing"
done
for entry in "${AI_PROVIDERS[@]}"; do
    bin=$(print -r -- "$entry" | cut -d'|' -f2)
    label=$(print -r -- "$entry" | cut -d'|' -f3)
    command -v "$bin" >/dev/null 2>&1 && ok "$label ready" || warn "$label not installed (optional — re-run this setup to add it)"
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
