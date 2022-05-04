#!/usr/bin/env bash

set -euxo pipefail

# A dvc stage with this script should be created with
#   dvc run --name <stage-name> --desc ... --deps ... --outs-persist ... --no-exec $(dvc root)/dvc_run_sbatch.ch <stage-name> command
# where command is bash -c "..." (... can include pipes, I/O redirection, etc.) and run with
#   dvc repro --no-commit <stage-name>

dvc_stage_name="$1" # stage name (uniquely characterizing output folder)
dvc_stage_app_yaml="$2"
dvc_stage_app_yaml_name="$3"
shift 3 # the rest is command to execute (using only dvc_stage_name as positional parameter, forward all others to sbatch)

set +x

SCRIPT_NAME="$(basename "$0")"
log () {
    echo "${SCRIPT_NAME}[${dvc_stage_name}]: $1"
}

log_error () {
    log "$1"
    exit 1
}

# Default configuration, can be overridden in the dvc repro environment
DVC_SLURM_DVC_OP_OUT_OF_REPO=${DVC_SLURM_DVC_OP_OUT_OF_REPO:-NO}  # run commit (and eventually push) out of repo (currently no speedup)
DVC_SLURM_DVC_OP_NO_HOLD=${DVC_SLURM_DVC_OP_NO_HOLD:-NO}          # put pending/running dvc commit/push ops on hold to enable continued use of dvc and then manual scontrol release
DVC_SLURM_DVC_PUSH_ON_COMMIT=${DVC_SLURM_DVC_PUSH_ON_COMMIT:-NO}  # don't enqueue dvc push job by default, leave this to user later

dvc_stage_from_dep () {
    echo "${1##*:}"
}

dvc_yaml_from_dep () {
    echo "${1%:*}"
}

dvc_root="$(dvc root)"

# TODO: separate script to source
# Append dvc root to SLURM job ID (due to repo-level lock)
dvc_stage_slurm_prefix="dvc"
dvc_stage_slurm_suffix=$(python3 -c "import hashlib; print(hashlib.sha1(\"$(realpath "${dvc_root}")\".encode(\"utf-8\")).hexdigest()[:12])") # equivalent to "$(echo -n $(realpath "${dvc_root}") | sha1sum | awk '{print $1}' | head -c 12)"
get_dvc_slurm_job_name () { # compute SLURM job name for DVC stage/commit in $1
  echo "${dvc_stage_slurm_prefix}_$(dvc_stage_from_dep "$1")_${dvc_stage_slurm_suffix}"
}

dvc_slurm_stage_name="$(get_dvc_slurm_job_name "${dvc_stage_name}")"
if [[ "${DVC_SLURM_DVC_OP_OUT_OF_REPO}" == "YES" ]]; then
    dvc_slurm_out_of_repo_commit_name="$(get_dvc_slurm_job_name "out_of_repo_commit_${dvc_stage_name}")"
fi
dvc_slurm_commit_name="$(get_dvc_slurm_job_name op)"
dvc_slurm_push_name="$(get_dvc_slurm_job_name op)"
dvc_slurm_cleanup_name="$(get_dvc_slurm_job_name "cleanup_${dvc_stage_name}")"

if [[ "${DVC_SLURM_DVC_OP_NO_HOLD}" != "YES" ]]; then  # YES is potentially unsafe
    log "Info: Putting any concurrent dvc commit or push operations on hold (use slurm_jobs.sh release later). Warning: Concurrent dvc operations cause a potential conflict for acquiring $(dvc root)/.dvc/tmp/rwlock) and dvc commands (incl. repro) will error out if they detect this."
    "$(dirname "$0")"/slurm_jobs.sh hold commit  # put commit jobs on hold due to potential race condition for DVC's rwlock
    "$(dirname "$0")"/slurm_jobs.sh hold push
fi

# Compute SLURM job opts, TODO: separately supply srun options (currently only sbatch supported)
dvc_slurm_opts_stage_job="$($(dirname "$0")/slurm_get_job_opts.py ${dvc_stage_app_yaml} ${dvc_stage_app_yaml_name} --stage)"
dvc_slurm_opts_dvc_job="$($(dirname "$0")/slurm_get_job_opts.py ${dvc_stage_app_yaml} ${dvc_stage_app_yaml_name} --dvc)"

# Check encfs and sarus configuration
if [[ "$*" =~ encfs_mount_and_run_v2.sh ]]; then
    if [ -z ${ENCFS_PW_FILE+x} ]; then
        log_error "Error: Env variable ENCFS_PW_FILE not set."
    elif [ ! -f ${ENCFS_PW_FILE} ]; then
        log_error "Error: File at path ENCFS_PW_FILE does not exist."
    fi
    if [[ ! -x "$(command -v encfs)" && ! -x "$(dirname "$0")../encfs_scripts/encfs/install/bin/encfs" && ! -x /apps/daint/UES/anfink/encfs/bin/encfs ]]; then
        if [ -z ${ENCFS_INSTALL_DIR+x} ]; then
            log_error "Error: Env variable ENCFS_INSTALL_DIR not set."
        elif [ ! -d "${ENCFS_INSTALL_DIR}" ]; then
            log_error "Error: encfs-installation directory at '${ENCFS_INSTALL_DIR}' (ENCFS_INSTALL_DIR) does not exist."
        elif [[ ! -f "${ENCFS_INSTALL_DIR}/bin/encfs" || ! -x "${ENCFS_INSTALL_DIR}/bin/encfs" ]]; then
            log_error "Error: Could not find/execute ${ENCFS_INSTALL_DIR}/bin/encfs."
        fi
    fi
fi


if [[ "$*" =~ sarus ]]; then
    if [[ ! -x "$(command -v sarus)" ]]; then
        log_error "Error: Could not find/execute sarus."
    fi
fi

# Get stage dependencies (dvc dag --dot doesn't need to move repo-lock temporarily)
dvc_stage_deps=()
while IFS= read -r dep; do
    if [ -n "${dep}" ]; then
        dvc_stage_deps+=("${dep}")
    fi
done <<< "$("$(dirname "$0")"/dvc_get_stage_deps.py ${dvc_stage_name})"

dvc_stage_outs=()
while IFS= read -r out; do
    if [ -n "${out}" ]; then
        dvc_stage_outs+=("${out}")
    fi
done <<< "$("$(dirname "$0")"/dvc_get_stage_outs.py ${dvc_stage_name})"

log "DVC stage deps of ${dvc_stage_name}: ${dvc_stage_deps[*]}"
log "DVC stage outs of ${dvc_stage_name}: ${dvc_stage_outs[*]}"
set -x

# Get status of dependencies - pending/started/complete/committed (stage can fail at any of the first two)
dep_slurm_stage_jobids=()
for dep in "${dvc_stage_deps[@]}"; do
    log "Looking for state of DVC dependency ${dep}."
    dep_dvc_dir="$(dirname "$(dvc_yaml_from_dep "${dep}")")"
    dep_dvc_stage_name="$(dvc_stage_from_dep "${dep}")"
    dep_slurm_stage_name="$(get_dvc_slurm_job_name "${dep}")"
    dep_slurm_stage_jobid=$(squeue --name="${dep_slurm_stage_name}" --Format=JobID --sort=-S -h)
     # check if SLURM dependency and pending/running
    if [ -n "${dep_slurm_stage_jobid}" ]; then
        dep_slurm_stage_jobids+=("${dep_slurm_stage_jobid}")
    elif [[ -f "${dep_dvc_dir}/${dep_dvc_stage_name}".dvc_pending || -f "${dep_dvc_dir}/${dep_dvc_stage_name}".dvc_started ]]; then  # stage is running # FIXME: what if dvc repro --single-item?
        for i in $(seq 1 5); do  # wait until SLURM job id of dependency is found
            dep_slurm_stage_jobid=$(squeue --name="${dep_slurm_stage_name}" --Format=JobID --sort=-S -h)
            if [ -n "${dep_slurm_stage_jobid}" ]; then # dependency is running
                dep_slurm_stage_jobids+=("${dep_slurm_stage_jobid}")
                break
            fi
            sleep 1
        done
        if [ ! -n "${dep_slurm_stage_jobid}" ]; then
            log_error "Error: Could not find SLURM job for ${dep} despite status pending or started - abort. Handle this stage manually by removing the status file $(ls "${dep_dvc_dir}/${dep_dvc_stage_name}".dvc_{pending,started}) and running 'dvc repro ${dep}' (or by running 'dvc commit ${dep}' if stage has completed)."
        fi
    # not a pending/started SLURM dependency - could be complete/committed/failed SLURM stage or no SLURM stage at all
    # if failed SLURM dependency, fail this one as well
    elif [ -f "${dep_dvc_dir}/${dep_dvc_stage_name}".dvc_failed ]; then  # stage SLURM job failed
        log_error "Error: DVC dependency ${dep} failed - abort."
    # check if SLURM dependency stage completed, but not yet committed (don't add as a SLURM dependency)
    elif [ -f "${dep_dvc_dir}/${dep_dvc_stage_name}".dvc_complete ]; then  # stage about to be completed (could show commit job ID here)
        log "DVC dependency ${dep} completed (but not yet committed) - no need to add as a SLURM dependency."
    # verify that stage has been committed, whether a SLURM dependency or not (don't add as a SLURM dependency)
    else
         log "No SLURM status (pending/started/complete/failed) set for DVC dependency ${dep} - assuming committed, skipping this dependency."
#        # This is probably unnecessary for dependencies as dvc repro would descend into it and reproduce it (otherwise with --single-item this is desired behavior)
#        mv "${dvc_root}"/.dvc/tmp/rwlock{,.bak}  # this causes the repro to fail if another dvc command (e.g. repro) acquires the rwlock before status has it
#        dep_status="$(dvc status --json "${dep}")"  # interpret with https://dvc.org/doc/command-reference/status#local-workspace-status
#        mv "${dvc_root}"/.dvc/tmp/rwlock{.bak,}  # silent failure if lock taken by other process (use atomic RENAME_EXCHANGE with renameat2 and check rwlock.bak content)
#        if [[ "${dep_status}" == "{}" ]]; then
#            log "DVC dependency ${dep} has been committed already - skipping this dependency."
#        else
#            log_error "Error: DVC dependency ${dep} with dvc status ${dep_status} neither committed nor with pending/running/completed/failed SLURM status - abort."
#        fi
    fi
done

# DVC stage job depends on all dependencies' stage jobs
if [ ${#dep_slurm_stage_jobids[@]} -gt 0 ]; then
    dvc_slurm_stage_deps=$(printf ",%s" "${dep_slurm_stage_jobids[@]}")
    dvc_slurm_stage_deps="--dependency afterok:${dvc_slurm_stage_deps:1}"
else
    dvc_slurm_stage_deps=""
fi

get_dvc_slurm_job_ids() {  # args are $1 SLURM job name, $2 stage|commit|push, $3 DVC stage name 
    while IFS=',' read -r job_id job_command; do
        if [[ -n "${job_id}" && "${job_command}" ]]; then
            read -r job_id <<<"${job_id}"
            read -ra job_command <<<"${job_command}"
            if [[ $(basename ${job_command[0]}) == sbatch_dvc_"$2".sh && ${job_command[1]} == $3 ]]; then
                log "Found $2-job $1 for DVC stage $3 at ${job_id}."
                echo ${job_id}
            fi
        fi
    done <<<$(squeue --jobs "$1" --format="%.30A,%.1000o" --sort=-S -h)
}

# Make sure stage is not already to be run, running, to be committed or committing
stage_jobid=$(squeue --name=${dvc_slurm_stage_name} --Format=JobID --sort=-S -h)
if [[ -n "${stage_jobid}" ]]; then # stage submitted, but not yet completed
  log "DVC stage ${dvc_stage_name} seems to already be queued/running under jobid ${stage_jobid} - do not resubmit."
  exit 0
elif [[ -f "${dvc_stage_name}".dvc_pending || -f "${dvc_stage_name}".dvc_started ]]; then  # stage is running
    for i in $(seq 1 5); do  # wait until SLURM job id of dependency is found
        stage_jobid=$(squeue --name="${dvc_slurm_stage_name}" --Format=JobID --sort=-S -h)
        if [ -n "${stage_jobid}" ]; then # dependency is running
            log "DVC stage ${dvc_stage_name} seems to already be queued/running under jobid ${stage_jobid} - do not resubmit."
            exit 0
        fi
        sleep 1
    done
    log_error "Error: Could not find SLURM job for ${dvc_stage_name} (job name ${dvc_slurm_stage_name}) despite status pending or started - abort. Handle this stage manually by removing the status file $(ls "${dvc_stage_name}".dvc_{pending,started}) and running 'dvc repro ${dvc_stage_name}' (or by running 'dvc commit ${dvc_stage_name}' if stage has completed)."
elif [ -f ${dvc_stage_name}.dvc_complete ]; then  # stage has completed, but is not yet committed
  # (detected with a file created before completion of run, removed upon completion of commit)
  log "DVC stage ${dvc_stage_name} completed successfully, but not yet committed - do not resubmit. Commit/push jobs may still be running. Commit manually if needed with 'sbatch --job-name "${dvc_slurm_commit_name}" --dependency singleton --nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_commit.sh" in-repo "${dvc_stage_name}"'"
  commit_jobids=($(get_dvc_slurm_job_ids "${dvc_slurm_commit_name}" commit "${dvc_stage_name}"))
  if [ "${#commit_jobids[@]}" -eq 0  ]; then 
      log "DVC stage ${dvc_stage_name} completed successfully, but no commit job running - resubmitting commit job."
      run_stage="NO"
      run_commit="YES"
  else  # commit job is running, do not resubmit
      log "DVC stage ${dvc_stage_name} completed successfully and found commit job running at ${commit_jobids[@]} - do not resubmit."
      exit 0
  fi
else  # stage was either committed since dvc repro invoked this (probably not possible?) or it must be re-run
  mv "${dvc_root}"/.dvc/tmp/rwlock{,.bak}  # see comment above (is this really necessary?)
  stage_status="$(dvc status --json ${dvc_stage_name})"
  mv "${dvc_root}"/.dvc/tmp/rwlock{.bak,}
  if [[ "${stage_status}" == "{}" ]]; then
      push_jobids=($(get_dvc_slurm_job_ids "${dvc_slurm_push_name}" push "${dvc_stage_name}"))
      if [ "${#push_jobids[@]}" -eq 0  ]; then 
          log "DVC stage ${dvc_stage_name} successfully committed in the meantime, but no push job running - optionally resubmitting push job."
          run_stage="NO"
          run_commit="NO"
          run_push="YES"
      else  # push job is running, do not resubmit
          log "DVC stage ${dvc_stage_name} successfully committed in the meantime and found push job running at ${push_jobids[@]} - do not resubmit."
          exit 0
      fi
  else
      log "Cannot find running/committed stage ${dvc_stage_name} - submitting it."
      run_stage="YES"
  fi
fi

log_submitted_jobs=()
if [[ "${DVC_SLURM_DVC_OP_NO_HOLD}" != "YES" ]]; then  # YES is potentially unsafe, the user invoking this must be aware of pot race condition
    dvc_slurm_hold_opts="--hold"
else
    dvc_slurm_hold_opts=""
fi

# application stage
if [[ "${run_stage}" == "YES" ]]; then
    log "Launching asynchronous stage ${dvc_stage_name} with SLURM"
    
    # Launch SLURM sbatch jobs

    # Clean up of any left-overs from previous run TODO: put this into sbatch_dvc_stage.sh as well (in case of requeue)
    for out in "${dvc_stage_outs[@]}"; do # coordinate outs-persist-handling with dvc_create_stage.py
        ls -I stage_out.log  "${out}" | xargs -I {} rm -r "${out}"/{} || true # correct dvc run --outs-persist behavior (used to avoid accidentally deleting files of completed, but not committed stages), requires mkdir -p <out_1> <out_2> ... in command
        mkdir -p "${out}" # output deps must be avaiable (as dirs) upon submission for dvc repro --no-commit to succeed
    done
    
    # Remove status/commit/cleanup logs from previous execution
    rm ${dvc_stage_name}.dvc_{pending,started,complete,failed} || true
    rm dvc_sbatch.dvc_commit.*.{out,err} || true
    rm dvc_sbatch.dvc_push.*.{out,err} || true
    rm slurm_enqueue_dvc_push_${dvc_stage_name}.sh || true
    rm dvc_sbatch.${dvc_slurm_cleanup_name}.*.{out,err} || true
    
    stage_jobid=$(sbatch --parsable --job-name "${dvc_slurm_stage_name}" ${dvc_slurm_stage_deps} ${dvc_slurm_hold_opts} ${dvc_slurm_opts_stage_job} "$(dirname "$0")/sbatch_dvc_stage.sh" "${dvc_stage_name}" "$@")
    echo "$@" > ${dvc_stage_name}.dvc_pending && fsync ${dvc_stage_name}.dvc_pending
    echo ${stage_jobid} > ${dvc_stage_name}.dvc_stage_jobid # useful to figure out run job id
    log_submitted_jobs+=("stage: ${stage_jobid}")

    cleanup_jobid=$(sbatch --parsable --job-name "${dvc_slurm_cleanup_name}" --dependency afternotok:${stage_jobid} \
    --nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_cleanup.sh" "${dvc_stage_name}" "${dvc_stage_outs[@]}")
    echo ${cleanup_jobid} > ${dvc_stage_name}.dvc_cleanup_jobid
    log_submitted_jobs+=("cleanup: ${cleanup_jobid}")
fi

# dvc commit
if [[ "${run_stage}" == "YES" || "${run_commit}" == "YES" ]]; then
    if [[ "${DVC_SLURM_DVC_OP_OUT_OF_REPO}" == "YES" ]]; then  # this feature currently doesn't speed up commits
        if [ -n "${stage_jobid}" ]; then
            dvc_slurm_commit_deps="--dependency afterok:${stage_jobid}"
        else
            dvc_slurm_commit_deps=""
        fi
        out_of_repo_commit_jobid=$(sbatch --parsable --job-name "${dvc_slurm_out_of_repo_commit_name}" ${dvc_slurm_commit_deps} ${dvc_slurm_hold_opts} --nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_commit.sh" out-of-repo-prepare "${dvc_stage_name}")
        echo ${out_of_repo_commit_jobid} > ${dvc_stage_name}.dvc_commit_out_of_repo_jobid
        log_submitted_jobs+=("out-of-repo-commit: ${out_of_repo_commit_jobid}")
        dvc_slurm_commit_deps="--dependency afterok:${out_of_repo_commit_jobid},singleton"
        commit_jobid=$(sbatch --parsable --job-name "${dvc_slurm_commit_name}" ${dvc_slurm_commit_deps} ${dvc_slurm_hold_opts} --nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_commit.sh" out-of-repo-commit "${dvc_stage_name}")
    else
        if [ -n "${stage_jobid}" ]; then
            dvc_slurm_commit_deps="--dependency afterok:${stage_jobid},singleton"
        else
            dvc_slurm_commit_deps="--dependency singleton"
        fi
        commit_jobid=$(sbatch --parsable --job-name "${dvc_slurm_commit_name}" ${dvc_slurm_commit_deps} ${dvc_slurm_hold_opts} --nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_commit.sh" in-repo "${dvc_stage_name}")
    fi
    echo ${commit_jobid} > ${dvc_stage_name}.dvc_commit_jobid  # useful to figure out which commit job (all named equally) commits this stage
    log_submitted_jobs+=("commit: ${commit_jobid}")
fi

# dvc push
if [[ "${run_stage}" == "YES" || "${run_commit}" == "YES" || "${run_push}" == "YES" ]]; then
    if [ -n "${commit_jobid}" ]; then
        dvc_slurm_push_deps="--dependency afterok:${commit_jobid},singleton"
    else
        dvc_slurm_push_deps="--dependency singleton"
    fi
    if [[ "${DVC_SLURM_DVC_PUSH_ON_COMMIT}" == "YES" ]]; then
        # TODO: out-of-repo version
        push_jobid=$(sbatch --parsable --job-name "${dvc_slurm_push_name}" ${dvc_slurm_push_deps} ${dvc_slurm_hold_opts} --nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_push.sh" in-repo "${dvc_stage_name}")
        echo ${push_jobid} > ${dvc_stage_name}.dvc_push_jobid # useful to figure out which push job (all named equally) commits this stage
        log_submitted_jobs+=("push: ${push_jobid}")
    else # write push op to a script for delayed manual submission through sbatch (before stage termination or if DVC jobs keep being run)
        push_script="slurm_enqueue_dvc_push_${dvc_stage_name}.sh"
        echo """#!/usr/bin/env bash

set -euxo pipefail

cd "\$\(dirname "\$0"\)"
push_jobid=\$(sbatch --parsable --job-name "${dvc_slurm_push_name}" ${dvc_slurm_push_deps} \
--nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")"/sbatch_dvc_push.sh in-repo "${dvc_stage_name}")
echo \${push_jobid} > ${dvc_stage_name}.dvc_push_jobid # useful to figure out which push job (all named equally) commits this stage

""" > ${push_script}
        chmod u+x ${push_script}
        log "Submit push job for ${dvc_stage_name} manually with ${push_script}."
    fi
fi

log_submitted_jobs=$(printf ", %s" "${log_submitted_jobs[@]}")
log "Submitted all jobs for stage ${dvc_stage_name} (${log_submitted_jobs:2})."

if [[ "${DVC_SLURM_DVC_OP_NO_HOLD}" != "YES" ]]; then  # YES is potentially unsafe, the user invoking this must be aware of pot race condition
    log "All jobs submitted on hold to enable further DVC usage. When ready, use 'scontrol release <job-id1> <job-id2> ...' to selectively unblock invidual jobs or '$(dirname $0)/slurm_jobs.sh release (stage|commit|push)' to unblock all jobs of particular type in this DVC repo."
else
    log "Warning: None of the jobs put on hold. Running more DVC commands may cause job failure (commit/push) due to conflict for $(dvc root)/.dvc/tmp/rwlock and induce unintentional hash recomputations. If you need to run further dvc commands, first put all your DVC SLURM jobs in this repo on hold using slurm_jobs.sh."
fi

