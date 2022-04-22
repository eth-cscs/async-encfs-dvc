#!/bin/bash -l

#SBATCH --output=dvc_sbatch.dvc_push.%j.out
#SBATCH --error=dvc_sbatch.dvc_push.%j.err

# Depends on successful execution and commit of corresponding DVC stage, which is to be run with dvc run/repro --no-commit as a preceding SLURM job.

set -euxo pipefail

echo "Running dvc push --verbose $@ (${SLURM_JOB_NAME})."
time srun --nodes 1 --ntasks 1 dvc push --verbose "$@"

