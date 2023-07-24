#!/usr/bin/env bash

# Benchmark implementation for iterative simulation (current step depending on previous one)

set -euo pipefail

ITERATIVE_SIM_BENCHMARK_DEBUGGING=0  # set to 1 for debugging
debug() {
    if [ "${ITERATIVE_SIM_BENCHMARK_DEBUGGING}" -eq 1 ]; then
        "$@"
    fi
}

SCRIPT_NAME="$(basename "$0")"
log () {
    echo "[${SCRIPT_NAME}] $1"
}

log_error () {
    log "$1"
    exit 1
}

dvc_repo_data_type=$(python3 <<EOF | tr -d '\n'
import yaml
dvc_root_yaml = yaml.load(open("$(dvc root)/.dvc_policies/repo/dvc_root.yaml").read(), yaml.FullLoader)
print(dvc_root_yaml['host_data']['mount']['data']['type'])
EOF
)

case ${dvc_repo_data_type} in
    plain)
        log "Running the benchmark on plain data."

        encrypt_prefix=""
        config_prefix=""
        ;;
    encfs)
        log "Running the benchmark on encfs-data."

        # using encfs at the moment (can be replaced without encryption by deleting encrypt/ and config/)
        if [ -z ${ENCFS_PW_FILE+x} ]; then
            log_error "Error: Env variable ENCFS_PW_FILE not set."
        elif [ ! -f ${ENCFS_PW_FILE} ]; then
            log_error "Error: File at path ENCFS_PW_FILE does not exist."
        fi

        encrypt_prefix=encrypt/
        config_prefix=config/
        ;;
    *)
        log_error "Data DVC repo data type ${dvc_repo_data_type} (should be either plain or encfs)"
        ;;
esac

debug set -x
case "$1" in
  none ) dvc_app_yaml=dvc_app.yaml ;;  # must be <= 10^6
  docker ) dvc_app_yaml=dvc_app_docker.yaml ;;
  slurm ) dvc_app_yaml=dvc_app_slurm.yaml ;;
  * ) echo "Unknown option $1 for container/app-yaml policy (allowed: none, docker, slurm)"; exit 1 ;;
esac
case "$2" in
  small-files ) output_files_per_rank=10000 ;;  # must be <= 10^6
  medium-files ) output_files_per_rank=1000 ;;
  large-files ) output_files_per_rank=1 ;;
  * ) echo "Unknown option $2 for output file size (allowed: small-files, medium-files or large-files)"; exit 1 ;;
esac
start_stage="$3"
end_stage="$4"
debug set +x

dvc_root="$(dvc root)"
dvc_root=$(realpath "${dvc_root}")
cd "${dvc_root}"
git_root=$(git rev-parse --show-toplevel)

# Create stage
log "Creating DVC pipeline!"

start=$(date +%s.%N)
set -x
# mock base dependency (for an input dataset stage use examples/in/dvc_app.yaml)
mkdir -p "${encrypt_prefix}"app_sim_v1/sim_dataset_v1/simulation/$((start_stage-1))/output
touch "${encrypt_prefix}"app_sim_v1/sim_dataset_v1/simulation/$((start_stage-1))/output/sim.0.dat

mkdir -p "${config_prefix}"app_sim_v1/sim_dataset_v1/simulation/$((start_stage-1))/output
REL_DVC_ROOT=$(realpath --relative-to="${config_prefix}"app_sim_v1/sim_dataset_v1/simulation/$((start_stage-1)) .)/
cd "${config_prefix}"app_sim_v1/sim_dataset_v1/simulation/$((start_stage-1)) && \
  dvc stage add --run --name app_sim_v1_sim_dataset_v1_simulation_$((start_stage-1)) \
    --outs-persist ${REL_DVC_ROOT}${encrypt_prefix}app_sim_v1/sim_dataset_v1/simulation/$((start_stage-1))/output true && \
  dvc freeze app_sim_v1_sim_dataset_v1_simulation_$((start_stage-1)) && \
  cd -

# actual benchmark stages
for i in $(seq ${start_stage} ${end_stage}); do
  dvc_create_stage --app-yaml ${git_root}/examples/app_sim/${dvc_app_yaml} --stage simulation \
    --run-label $i --input-simulation $((i-1)) \
    --simulation-output-file-num-per-rank ${output_files_per_rank} \
    --simulation-output-file-size $((10**9 * 2**(i-start_stage) / output_files_per_rank))
done
set +x
end=$(date +%s.%N)
stage_creation_time_sec=$( echo "$end - $start" | bc -l )

log "Creating $((end_stage - start_stage + 1)) DVC stages took ${stage_creation_time_sec} seconds."
# exit 0  # uncomment to only create the pipeline and manually launch it later

log "Launching DVC pipeline!"

# Run stage
start=$(date +%s.%N)
set -x
cd "${config_prefix}"app_sim_v1/sim_dataset_v1/simulation/${end_stage}
set +x
dvc repro --no-commit app_sim_v1_sim_dataset_v1_simulation_${end_stage}
end=$(date +%s.%N)
stage_execution_time_sec=$( echo "$end - $start" | bc -l )

log "Executing $((end_stage - start_stage + 1)) DVC stages took ${stage_execution_time_sec} seconds."
