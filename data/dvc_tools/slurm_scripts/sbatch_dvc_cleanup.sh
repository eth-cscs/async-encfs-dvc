#!/bin/bash -l

#SBATCH --output=dvc_sbatch.%x.%j.out
#SBATCH --error=dvc_sbatch.%x.%j.err

# Depends on unsuccessful execution of corresponding DVC stage, which
# is to be run with dvc repro --no-commit as a preceding SLURM job.

set -euxo pipefail

dvc_stage_name="$1"
shift

echo "Cleaning up failed dvc stage ${dvc_stage_name} (${SLURM_JOB_NAME}) with outs $@."
ls -al 
if [ -f "${dvc_stage_name}".dvc_pending ]; then
    mv "${dvc_stage_name}".dvc_pending "${dvc_stage_name}".dvc_failed && fsync "${dvc_stage_name}".dvc_failed  # could protect by flock
    echo "Stage was pending (not yet started)."
elif [ -f "${dvc_stage_name}".dvc_started ]; then
    mv "${dvc_stage_name}".dvc_started "${dvc_stage_name}".dvc_failed && fsync "${dvc_stage_name}".dvc_failed  # could protect by flock
    echo "Stage was started - skipping \'rm -r "$@"\' to enable post-mortem analysis"
fi
rm dvc.lock  # ensure that this stage gets re-executed upon dvc repro

