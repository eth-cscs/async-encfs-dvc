#!/bin/bash -l

#SBATCH --output=dvc_sbatch.dvc_push.%j.out
#SBATCH --error=dvc_sbatch.dvc_push.%j.err

# Depends on successful execution and commit of corresponding DVC stage, which is to be run with dvc run/repro --no-commit as a preceding SLURM job.

set -euxo pipefail

case $1 in
    in-repo)
        in_repo=YES
        ;;
    out-of-repo)
        in_repo=NO
        ;;
    *)
        echo "Unknown option '$1' (choose either in-repo or out-of-repo)."
        exit 1
        ;;
esac
dvc_stage_name="$2"
shift 2

if [[ ${in_repo} == NO ]]; then
  source "$(dvc root)"/../dvc_tools/slurm_scripts/dvc_out_of_repo.sh
  # setup auxiliary repo
  dvc_out_of_repo_init
fi

echo "Running dvc push --verbose $@ (${SLURM_JOB_NAME})."
time srun --nodes 1 --ntasks 1 dvc push --verbose "${dvc_stage_name}"

if [[ ${in_repo} == NO ]]; then
  # cleanup auxiliary repo
  dvc_out_of_repo_cleanup
fi
