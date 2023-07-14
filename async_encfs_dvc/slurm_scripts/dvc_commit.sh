#!/usr/bin/env bash

# Example for using out-of-repo commits (no SLURM-dependency), and what is required to fix them

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
  source "$(dirname "$0")"/dvc_out_of_repo.sh
  stage_dir=$(realpath --relative-to=$(dvc root) .)
  repo_dir=$(realpath --relative-to=$(dvc root)/.. $(dvc root))
  
  # setup auxiliary repo
  dvc_out_of_repo_init
  aux_repo_dir=$(realpath --relative-to=.. .)

  # 1. commit out-of-repo (analogous for out-of-repo dvc pull, out-of-repo dvc push first needs a pull from the main repo)
  echo "Committing dvc stage $@ out of repo (prepare step)."
  time dvc commit --verbose --force "${stage_dir}/dvc.yaml:${dvc_stage_name}"

  cd ../${repo_dir}

  # 2. pull commit from main repo
  dvc remote add --verbose local_temp ../${aux_repo_dir}/.dvc/cache  # extra local dvc pull (safest option)
  echo "Committing dvc stage $@ out of repo (commit step)."
  time dvc pull --remote local_temp "${stage_dir}/dvc.yaml:${dvc_stage_name}"  # FIXME: still triggers hash computation on pulled files - need to find a way to pull also cache.db content
  dvc remote remove --verbose local_temp

  # cleanup auxiliary repo
  cd ../${aux_repo_dir}
  dvc_out_of_repo_cleanup
else
  # commit in the main repo
  echo "Committing dvc stage $@."
  time dvc commit --verbose --force "${dvc_stage_name}" 
fi

