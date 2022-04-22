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

# using encfs at the moment (can be replaced without encryption by deleting encrypt/ and config/)
if [ -z ${ENCFS_PW_FILE+x} ]; then
    log_error "Error: Env variable ENCFS_PW_FILE not set."
elif [ ! -f ${ENCFS_PW_FILE} ]; then
    log_error "Error: File at path ENCFS_PW_FILE does not exist."
fi
encrypt_prefix=encrypt/
config_prefix=config/

source "$(dirname "$0")"/iterative_sim_base_benchmark.sh
