#!/usr/bin/env bash

# Requires dvc_stage_name to be defined (stage name without dvc.yaml)

# change dir to auxiliary repo
dvc_out_of_repo_cd() {
  dvc_root=$(dvc root)
  stage_dir=$(realpath --relative-to=${dvc_root} .)
  stage_hash=$(echo -n ${stage_dir}/dvc.yaml:${dvc_stage_name} | sha1sum | awk '{print $1}' | head -c 12)
  repo_dir=$(realpath --relative-to=${dvc_root}/.. ${dvc_root})
  aux_repo_dir=${repo_dir}_${dvc_stage_name}_${stage_hash}
  cd ${dvc_root}/../${aux_repo_dir}  # /${stage_dir} # skipped stage_dir as commands should be run in dvc root (otherwise dvc picks up original repo)
}

# setup and change to auxiliary repo
dvc_out_of_repo_init() {
  dvc_root=$(dvc root)
  stage_dir=$(realpath --relative-to=${dvc_root} .)
  stage_hash=$(echo -n ${stage_dir}/dvc.yaml:${dvc_stage_name} | sha1sum | awk '{print $1}' | head -c 12)
  repo_dir=$(realpath --relative-to=${dvc_root}/.. ${dvc_root})
  aux_repo_dir=${repo_dir}_${dvc_stage_name}_${stage_hash}

  if [ ! -z ${IFS+z} ]; then
      OLD_IFS="${IFS}"
  else
      unset OLD_IFS
  fi

  cd ${dvc_root}
  IFS=$'\n' sym_links=( $(ls -1 -I venv .) )
  IFS=$'\n' dvc_remotes=( $(dvc remote list) )
  mkdir ../${aux_repo_dir} && cd ../${aux_repo_dir}

  echo "Creating symbolic links for top folders/files ${sym_links[@]}."
  for file in "${sym_links[@]}"; do
    ln -s ../${repo_dir}/${file} ${file}
  done

  dvc init --no-scm
  for remote in "${dvc_remotes[@]}"; do  # for out of repo pushing/pulling
    IFS=$' \t\n' read -ra remote <<<"${remote}"
    dvc remote add ${remote[0]} ${remote[1]}
  done
  #ln -s ../../${repo_dir}/.dvc/cache .dvc/cache  # previously symbolically linked .dvc/cache to avoid extra dvc push (unsafe)
  #dvc remote add local_temp ../${repo_dir}/.dvc/cache  # previously for extra local dvc push to main repo (unsafe, prefer customized dvc pull from main repo)
  #cd ${stage_dir}  # skipped as commands should be run in dvc root (otherwise dvc picks up original repo)

  if [ ! -z ${OLD_IFS+z} ]; then
      IFS="${OLD_IFS}"
  else
      unset IFS
  fi
}

# cleanup from auxiliary repo
dvc_out_of_repo_cleanup() {
  if [ ! -z ${IFS+z} ]; then
      OLD_IFS="${IFS}"
  fi

  cd "$(dvc root)"
  IFS=$'\n' sym_links=( $(find . -maxdepth 1 -type l) )
  rm "${sym_links[@]}" #  .dvc/cache # FIXME: uncomment .dvc/cache here if symlink to local main repo
  rm -r .dvc*
  rmdir "$(pwd)"

  if [ ! -z ${OLD_IFS+z} ]; then
      IFS="${OLD_IFS}"
  else
      unset IFS
  fi
}
