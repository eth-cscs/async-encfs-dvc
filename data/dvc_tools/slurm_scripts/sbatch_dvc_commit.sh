#!/bin/bash -l

#SBATCH --output=dvc_sbatch.dvc_commit.%j.out
#SBATCH --error=dvc_sbatch.dvc_commit.%j.err

# Depends on successful execution of corresponding DVC stage, which is to be run with dvc run/repro --no-commit as a preceding SLURM job.

set -euxo pipefail

dvc_stage_name="$1"
shift

echo "Committing dvc stage $@ (${SLURM_JOB_NAME})."
time srun --nodes 1 --ntasks 1 dvc commit --verbose --force "${dvc_stage_name}"  # echo y | dvc commit $@
rm "${dvc_stage_name}".dvc_complete  # could protect by flock
# dvc push for now in separate job, but could be integrated with this one as an additional SLURM step

