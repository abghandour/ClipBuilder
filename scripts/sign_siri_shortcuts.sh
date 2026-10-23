#!/bin/zsh
# Generates and signs the "Clip Builder Dub <Voice>" shortcuts that let the app
# dub with Siri voices, then drops them where the app bundle picks them up.
#
# Shortcuts refuses unsigned .shortcut files and `shortcuts sign` only works on
# a Mac signed into iCloud, so this runs on such a Mac, once per voice set:
#
#   scripts/sign_siri_shortcuts.sh            # all known voices
#   scripts/sign_siri_shortcuts.sh Nando pt-BR Sandra pt-BR
#
# Output: ClipBuilder/Resources/Shortcuts/Clip Builder Dub <Voice>.shortcut
# (signed, mode "anyone"). The app offers "Add shortcut" with one click when
# the file is bundled; otherwise it shows the manual steps.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/ClipBuilder/Resources/Shortcuts"
WORK="$(mktemp -d)"
mkdir -p "$OUT"

typeset -a PAIRS
if (( $# > 0 )); then
    PAIRS=("$@")
else
    PAIRS=(Nando pt-BR Sandra pt-BR Aaron en-US Nicky en-US)
fi
if (( ${#PAIRS} % 2 != 0 )); then
    echo "usage: $0 [<Voice> <language> ...]" >&2
    exit 2
fi

for (( i = 1; i <= ${#PAIRS}; i += 2 )); do
    name="${PAIRS[$i]}"
    language="${PAIRS[$((i + 1))]}"
    shortcut="Clip Builder Dub $name"
    unsigned="$WORK/$shortcut.shortcut"
    python3 - "$unsigned" "$name" "$language" <<'PY'
import plistlib, sys, uuid
path, name, language = sys.argv[1:4]
speak = str(uuid.uuid4()).upper()
token = lambda att: {"Value": {"attachmentsByRange": {"{0, 1}": att}, "string": "￼"}, "WFSerializationType": "WFTextTokenString"}
plistlib.dump({
    "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowClientVersion": "2607.0.3", "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowImportQuestions": [], "WFWorkflowInputContentItemClasses": ["WFStringContentItem"], "WFWorkflowTypes": [],
    "WFWorkflowActions": [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.makespokenaudiofromtext",
         "WFWorkflowActionParameters": {"UUID": speak, "WFInput": token({"Type": "ExtensionInput"}),
                                        "WFSpeakTextLanguage": language,
                                        "WFSpeakTextVoice": "com.apple.siri.natural." + name}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.output",
         "WFWorkflowActionParameters": {"UUID": str(uuid.uuid4()).upper(),
                                        "WFOutput": token({"OutputName": "Spoken Audio", "OutputUUID": speak, "Type": "ActionOutput"})}},
    ],
}, open(path, "wb"))
PY
    shortcuts sign --mode anyone --input "$unsigned" --output "$OUT/$shortcut.shortcut"
    echo "signed: $OUT/$shortcut.shortcut"
done
rm -rf "$WORK"
