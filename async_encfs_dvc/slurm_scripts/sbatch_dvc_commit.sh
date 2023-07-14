#!/bin/bash -l

#SBATCH --output=dvc_sbatch.dvc_commit.%j.out
#SBATCH --error=dvc_sbatch.dvc_commit.%j.err

# Depends on successful execution of corresponding DVC stage, which is to be run with dvc stage add/repro --no-commit as a preceding SLURM job, and potentially out-of-repo commit.

set -euxo pipefail

case $1 in
    in-repo)
        in_repo=YES
        ;;
    out-of-repo-prepare)
        in_repo=NO
        out_of_repo_commit=NO
        ;;
    out-of-repo-commit)
        in_repo=NO
        out_of_repo_commit=YES
        ;;
    *)
        echo "Unknown option '$1' (choose either in-repo or out-of-repo-(prepare|commit))."
        exit 1
        ;;
esac
dvc_stage_name="$2"
shift 2


if [[ ${in_repo} == NO ]]; then
  source "$(dvc root)"/../dvc_tools/slurm_scripts/dvc_out_of_repo.sh
  stage_dir=$(realpath --relative-to=$(dvc root) .)
  repo_dir=$(realpath --relative-to=$(dvc root)/.. $(dvc root))

  if [[ ${out_of_repo_commit} == NO ]]; then 
    # 1. prepare step (dvc commit of stage in auxiliary repo)

    # setup auxiliary repo
    dvc_out_of_repo_init

    echo "Committing dvc stage $@ out of repo (prepare step, ${SLURM_JOB_NAME})."
    time srun --nodes 1 --ntasks 1 dvc commit --verbose --force "${stage_dir}/dvc.yaml:${dvc_stage_name}"
     
    # dvc_out_of_repo_cleanup must be called in subsequent job that pushes to local remote
  else
    # 2. commit step

    # cd to auxiliary repo
    dvc_out_of_repo_cd 
    aux_repo_dir=$(realpath --relative-to=.. .)
    cd ../${repo_dir}
        
    dvc remote add --verbose local_temp ../${aux_repo_dir}/.dvc/cache  # extra local dvc pull (safer)
    echo "Committing dvc stage $@ out of repo (commit step, ${SLURM_JOB_NAME})."
    time srun --nodes 1 --ntasks 1  dvc pull --remote local_temp "${stage_dir}/dvc.yaml:${dvc_stage_name}"  # FIXME: still triggers hash computation on pulled files - need to find a way to pull also cache.db content
    rm "${stage_dir}/${dvc_stage_name}".dvc_complete  # could protect by flock
    dvc remote remove --verbose local_temp

    # cleanup auxiliary repo
    cd ../${aux_repo_dir}
    dvc_out_of_repo_cleanup

#    # version with push to .dvc/cache (pull-based version probably safer)
#    # cd to auxiliary repo
#    dvc_out_of_repo_cd 
#    cd $(dvc root) # as DVC picks up main repo to perform its command on when inside the dir linked by the symlink
#    echo "Committing dvc stage $@ out of repo (commit step, ${SLURM_JOB_NAME})."
#    time srun --nodes 1 --ntasks 1  dvc push --remote local_temp "${stage_dir}/dvc.yaml:${dvc_stage_name}"  # (should this be protected by a lock/mutual exclusion?)
#    
#    rm "${stage_dir}/${dvc_stage_name}".dvc_complete  # could protect by flock
#    # dvc push for now in separate job, but could be integrated with this one as an additional SLURM step
#
#    # cleanup auxiliary repo
#    dvc_out_of_repo_cleanup
  fi
else
  ## in-repo commit
  echo "Committing dvc stage $@ (${SLURM_JOB_NAME})."
  time srun --nodes 1 --ntasks 1 dvc commit --verbose --force "${dvc_stage_name}"  # echo y | dvc commit $@
  rm "${dvc_stage_name}".dvc_complete  # could protect by flock
  # dvc push for now in separate job, but could be integrated with this one as an additional SLURM step
fi

