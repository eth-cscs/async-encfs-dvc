# Benchmark implementation for iterative simulation (current step depending on previous one)

set -x
case "$1" in
  small-files ) output_files_per_rank=10000 ;;  # must be <= 10^6
  medium-files ) output_files_per_rank=1000 ;;
  large-files ) output_files_per_rank=1 ;;
  * ) echo "Unknown option $1 for output file size (allowed: small-files, medium-files or large-files)"; exit 1 ;;
esac
start_stage="$2"
end_stage="$3"
set +x

dvc_root="$(dvc root)"
dvc_root=$(realpath "${dvc_root}")
cd "${dvc_root}"

# Create stage
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
  dvc_create_stage --app-yaml $(git rev-parse --show-toplevel)/examples/app_sim/dvc_app.yaml --stage simulation \
    --run-label $i --input-simulation $((i-1)) \
    --simulation-output-file-num-per-rank ${output_files_per_rank} \
    --simulation-output-file-size $((10**9 * 2**(i-start_stage) / output_files_per_rank))
done
set +x
end=$(date +%s.%N)
stage_creation_time_sec=$( echo "$end - $start" | bc -l )

log "Creating $((end_stage - start_stage + 1)) DVC stages took ${stage_creation_time_sec} seconds."
# exit 0  # uncomment to only create the pipeline and manually launch it later

# Run stage
start=$(date +%s.%N)
set -x
cd "${config_prefix}"app_sim_v1/sim_dataset_v1/simulation/${end_stage}
dvc repro app_sim_v1_sim_dataset_v1_simulation_${end_stage}
set +x
end=$(date +%s.%N)
stage_execution_time_sec=$( echo "$end - $start" | bc -l )

log "Executing $((end_stage - start_stage + 1)) DVC stages took ${stage_execution_time_sec} seconds."
