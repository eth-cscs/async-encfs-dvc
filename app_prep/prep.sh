#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
log () {
    echo "${SCRIPT_NAME}: $1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --etl-input ) ETL_INPUT="$2"; shift 2 ;;
    --etl-output ) ETL_OUTPUT="$2"; shift 2 ;;
    * ) break ;;
  esac
done

set -x
cp "${ETL_INPUT}" "${ETL_OUTPUT}"