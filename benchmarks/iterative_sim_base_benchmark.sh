# Benchmark implementation for iterative simulation (current step depending on previous one)

set -x
dvc_root=$(realpath "$1")
case "$2" in
  small ) output_files_per_rank=10000 ;;  # must be <= 10^6
  medium ) output_files_per_rank=1000 ;;
  large ) output_files_per_rank=1 ;;
  * ) echo "Unknown option $1 for output file size (allowed: small, medium or large)"; exit 1 ;;
esac
start_stage="$3"
end_stage="$4"
cd "$(dirname "$0")"
set +x

# Create stage
start=$(date +%s.%N)
set -x
mkdir -p "${dvc_root}/${encrypt_prefix}"app_sim/v1/simulation/$((start_stage-1))/output
touch "${dvc_root}/${encrypt_prefix}"app_sim/v1/simulation/$((start_stage-1))/output/sim.0.dat  # initial dependency
for i in $(seq ${start_stage} ${end_stage}); do
  ../data/dvc_tools/dvc_create_stage --app-yaml ../app_sim/dvc_app.yaml --stage simulation \
    --run-label $i --input-simulation $((i-1)) \
    --simulation-output-file-num-per-rank ${output_files_per_rank} \
    --simulation-output-file-size $((10**9 * 2**(i-start_stage) / output_files_per_rank))
done
set +x
end=$(date +%s.%N)
stage_creation_time_sec=$( echo "$end - $start" | bc -l )

log "Creating $((end_stage - start_stage + 1)) DVC stages took ${stage_creation_time_sec} seconds."
exit 0  # manually launch pipeline

# Run stage
start=$(date +%s.%N)
set -x
cd "${dvc_root}/${config_prefix}"app_sim/v1/simulation/${end_stage}
dvc repro app_sim_v1_simulation_${end_stage}
set +x
end=$(date +%s.%N)
stage_execution_time_sec=$( echo "$end - $start" | bc -l )

log "Executing $((end_stage - start_stage + 1)) DVC stages took ${stage_execution_time_sec} seconds."
