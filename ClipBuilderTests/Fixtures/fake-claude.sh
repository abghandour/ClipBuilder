#!/bin/zsh
set -euo pipefail

# Canned replies keyed by a marker in the prompt. Order matters: the
# analysis prompt mentions captions and durations too, so it is checked
# first; the plan prompt names its "target_duration" key; anything else
# is treated as a caption request.
INPUT="$(cat)"
if [[ "$INPUT" == *'suggested_filename'* ]]; then
    TEXT='{\"tags\":{\"striking\":[{\"start\":0,\"end\":3}]},\"moments\":[{\"time\":1.0,\"description\":\"fixture moment\"}],\"people\":[],\"suggested_filename\":null}'
elif [[ "$INPUT" == *'target_duration'* ]]; then
    TEXT='{\"target_duration\":3,\"rationale\":\"fixture\",\"clips\":[{\"scene_id\":1,\"start\":0,\"end\":3}],\"transitions\":[]}'
else
    TEXT='{\"caption\":\"Fixture caption\"}'
fi
print -r -- "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$TEXT\"}]}}"
