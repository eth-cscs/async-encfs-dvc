#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
log () {
    echo "${SCRIPT_NAME}: $1"
}

# parse arguments
help_message() {
cat << EOF
  usage "$0" [OPTION]...

  OPTIONS
    --source   configuration file to copy
    --dest     output directory
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help ) help_message; shift; exit 0 ;;
    --source ) COPY_SOURCE="$2"; shift 2 ;;
    --dest ) COPY_DEST="$2"; shift 2 ;;
    * ) log "Error: unknown option $1"; exit 1 ;;
  esac
done

cp -v "${COPY_SOURCE}" "${COPY_DEST}"
