#!/usr/bin/env bash

# Benchmark for iterative simulation (current step depending on previous one)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
log () {
    echo "${SCRIPT_NAME}: $1"
}

log_error () {
    log "$1"
    exit 1
}

encrypt_prefix=""
config_prefix=""

source "$(dirname "$0")"/iterative_sim_base_benchmark.sh
