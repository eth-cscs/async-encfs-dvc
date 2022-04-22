#!/bin/bash -l

#SBATCH --output=output/dvc_sbatch.%x.%j.out
#SBATCH --error=output/dvc_sbatch.%x.%j.err

# to be run with dvc run/repro --no-commit! (the first SLURM job runs the actual workload, the second one commits it to DVC)

set -euxo pipefail

dvc_stage_name="$1"
shift

echo "Running dvc stage ${SLURM_JOB_NAME}."
mv "${dvc_stage_name}".dvc_pending "${dvc_stage_name}".dvc_started && fsync "${dvc_stage_name}".dvc_started  # could protect by flock
time srun --wait=300 "$@"  # --wait to allow more asymmetric task completion than 30 sec, especially with encfs (TODO: separate srun from sbatch options in dvc_app.yaml)
mv "${dvc_stage_name}".dvc_started "${dvc_stage_name}".dvc_complete && fsync "${dvc_stage_name}".dvc_complete  # could protect by flock

