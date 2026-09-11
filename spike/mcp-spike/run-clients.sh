#!/bin/bash
set -euo pipefail
# Configs, private working directories, and logs all stay inside this spike.
SPIKE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SPIKE_DIR/run_clients.py" "$@"
