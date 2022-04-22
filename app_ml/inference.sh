#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
log () {
    echo "${SCRIPT_NAME}: $1"
}

log "cd /src/app"
log "source venv/bin/activate"

set -x
exec python3 -u "$(dirname "$0")"/inference.py "$@"