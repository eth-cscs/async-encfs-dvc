#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
log () {
    echo "${SCRIPT_NAME}: $1"
}

# parse arguments (following https://stackoverflow.com/questions/402377/using-getopts-to-process-long-and-short-command-line-options)
help_message() {
cat << EOF
  usage "$0" [OPTION]...

  OPTIONS
    --simulation-input input file to this simulation
    --simulation-output output file of this simulation
    --simulation-output-file-size size of individual output files (e.g. 2K, 17M, 2G)
    --simulation-output-file-num-per-rank number of output files (e.g. 1, 500, 10000)
EOF
}

SIMULATION_INPUT=
SIMULATION_OUTPUT=
SIMULATION_OUTPUT_FILE_SIZE=
SIMULATION_OUTPUT_FILE_NUM=
DEBUG=false
VERBOSE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help ) help_message; shift; exit 0 ;;
    -v | --verbose ) VERBOSE=true; shift ;;
    -d | --debug ) DEBUG=true; shift ;;
    --simulation-input ) SIMULATION_INPUT="$2"; shift 2 ;;
    --simulation-output ) SIMULATION_OUTPUT="$2"; shift 2 ;;
    --simulation-output-file-size ) SIMULATION_OUTPUT_FILE_SIZE="$2"; shift 2 ;;
    --simulation-output-file-num-per-rank ) SIMULATION_OUTPUT_FILE_NUM="$2"; shift 2 ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

# Get MPI rank from environment
if [ ! -z "${SLURM_PROCID+x}" ]; then
    MPI_RANK=${SLURM_PROCID}
elif [ ! -z "${OMPI_COMM_WORLD_RANK+x}" ]; then
    MPI_RANK=${OMPI_COMM_WORLD_RANK}
elif [ ! -z "${PMI_RANK+x}" ]; then
    MPI_RANK=${PMI_RANK}
elif [ ! -z "${PMIX_RANK+x}" ]; then
    MPI_RANK=${PMIX_RANK}
else
    log "Unable to determine MPI rank - assuming to run in non-distributed mode (as a single process)."
    MPI_RANK=0
fi

SIMULATION_OUTPUT_FILES=()
for file_num in $(seq 0 $((SIMULATION_OUTPUT_FILE_NUM -1 ))); do
  SIMULATION_OUTPUT_FILES+=("${SIMULATION_OUTPUT}/sim.${MPI_RANK}.${file_num}.dat")
done
log "Running simulation on rank ${MPI_RANK}, writing output to ${SIMULATION_OUTPUT_FILES[0]} (first file, total number of files: ${#SIMULATION_OUTPUT_FILES[@]})."

set -x
for output_file in "${SIMULATION_OUTPUT_FILES[@]}"; do
  dd if=/dev/urandom \
     of="${output_file}" \
     bs=4k iflag=fullblock,count_bytes count=${SIMULATION_OUTPUT_FILE_SIZE}
done
