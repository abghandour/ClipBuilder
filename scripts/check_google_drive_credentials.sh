#!/bin/sh
# Validate configuration without printing either value. Also run on the built app.
set -eu
file=${1:?Usage: check_google_drive_credentials.sh path-to-plist}
for key in GoogleOAuthClientID GoogleOAuthClientSecret; do
    value=$(/usr/bin/plutil -extract "$key" raw -expect string -o - "$file" 2>/dev/null) || value=""
    case "$value" in
        ''|*'$('*|*'${'*) valid=false ;;
        *)
            if [ -n "$(printf '%s' "$value" | tr -d '[:space:]')" ]; then valid=true; else valid=false; fi ;;
    esac
    if [ "$valid" = false ]; then
        echo 'error: Google Drive release credentials are missing. Complete the developer build setup in docs/Google-Drive-Setup.md before packaging.' >&2
        exit 1
    fi
done
