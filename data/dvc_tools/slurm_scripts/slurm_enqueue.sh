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
DVC_SLURM_DVC_OP_NO_HOLD=${DVC_SLURM_DVC_OP_NO_HOLD:-NO}  # put pending/running dvc commit/push ops on hold during dvc repro execution (due to potential race condition)
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
dvc_stage_slurm_suffix=$(python3 -c "import hashlib; print(hashlib.sha1(\"$(realpath "${dvc_root}")\".encode(\"utf-8\")).hexdigest()[:12])") # "$(realpath "${dvc_root}" | sha1sum | head -c 12)"
get_dvc_slurm_job_name () { # compute SLURM job name for DVC stage/commit in $1
  echo "${dvc_stage_slurm_prefix}_$(dvc_stage_from_dep "$1")_${dvc_stage_slurm_suffix}"
}

dvc_slurm_stage_name="$(get_dvc_slurm_job_name "${dvc_stage_name}")"
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
        for i in $(seq 1 15); do  # wait until SLURM job id of dependency is found
            dep_slurm_stage_jobid=$(squeue --name="${dep_slurm_stage_name}" --Format=JobID --sort=-S -h)
            if [ -n "${dep_slurm_stage_jobid}" ]; then # dependency is running
                dep_slurm_stage_jobids+=("${dep_slurm_stage_jobid}")
                break
            fi
            sleep 1
        done
        if [ ! -n "${dep_slurm_stage_jobid}" ]; then
          log_error "Error: Could not find SLURM job for ${dep} despite status pending or started - abort. Handle this stage manually - either by removing the status file $(ls "${dep_dvc_dir}/${dep_dvc_stage_name}".dvc_{pending,started}) and running 'dvc repro ${dep}' or by running 'dvc commit ${dep}'."
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

# Make sure stage is not already to be run, running, to be committed or committing
stage_jobid=$(squeue --name=${dvc_slurm_stage_name} --Format=JobID --sort=-S -h)
if [[ -n "${stage_jobid}" ]]; then # stage submitted, but not yet completed
  log "DVC stage ${dvc_stage_name} seems to already be queued/running under jobid ${stage_jobid} - do not resubmit."
  exit 0
elif [[ -f "${dvc_slurm_stage_name}".dvc_pending || -f "${dvc_slurm_stage_name}".dvc_started ]]; then  # stage is running
    for i in $(seq 1 15); do  # wait until SLURM job id of dependency is found
        stage_jobid=$(squeue --name="${dvc_slurm_stage_name}" --Format=JobID --sort=-S -h)
        if [ -n "${stage_jobid}" ]; then # dependency is running
            log "DVC stage ${dvc_stage_name} seems to already be queued/running under jobid ${stage_jobid} - do not resubmit."
            exit 0
        fi
        sleep 1
    done
    log_error "Error: Could not find SLURM job for ${stage_jobid} despite status pending or started. - abort."
elif [ -f ${dvc_stage_name}.dvc_complete ]; then
  # stage has completed, but is not yet committed
  # (detected with a file created before completion of run, removed upon completion of commit)
  log "DVC stage ${dvc_stage_name} completed successfully, but not yet committed - do not resubmit."
  exit 0
else
  mv "${dvc_root}"/.dvc/tmp/rwlock{,.bak}  # see comment above (is this really necessary?)
  stage_status="$(dvc status --json ${dvc_stage_name})"
  mv "${dvc_root}"/.dvc/tmp/rwlock{.bak,}
  if [[ "${stage_status}" == "{}" ]]; then
      log "DVC stage ${dvc_stage_name} already committed - do not resubmit."
      exit 0
  else
      log "Cannot find running/committing stage ${dvc_stage_name} - submitting."
  fi
fi

log "Launching asynchronous stage ${dvc_stage_name} with SLURM"

# Launch SLURM sbatch jobs
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

stage_jobid=$(sbatch --parsable --job-name "${dvc_slurm_stage_name}"  ${dvc_slurm_stage_deps} \
${dvc_slurm_opts_stage_job} "$(dirname "$0")/sbatch_dvc_stage.sh" "${dvc_stage_name}" "$@")
echo "$@" > ${dvc_stage_name}.dvc_pending && fsync ${dvc_stage_name}.dvc_pending
echo ${stage_jobid} > ${dvc_stage_name}.dvc_stage_jobid # useful to figure out run job id

commit_jobid=$(sbatch --parsable --job-name "${dvc_slurm_commit_name}" --dependency afterok:${stage_jobid},singleton \
--nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_commit.sh" "${dvc_stage_name}")
echo ${commit_jobid} > ${dvc_stage_name}.dvc_commit_jobid # useful to figure out which commit job (all named equally) commits this stage
if [[ "${DVC_SLURM_DVC_OP_NO_HOLD}" != "YES" ]]; then  # YES is potentially unsafe, the user invoking this must be aware of pot race condition
    scontrol hold ${commit_jobid}
    log "Put dvc commit job ${commit_jobid} on hold - use 'scontrol release ${commit_jobid}' to selectively unblock it or '$(dirname $0)/slurm_jobs.sh release commit' to unblock all commit jobs."
fi

cleanup_jobid=$(sbatch --parsable --job-name "${dvc_slurm_cleanup_name}" --dependency afternotok:${stage_jobid} \
--nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_cleanup.sh" "${dvc_stage_name}" "${dvc_stage_outs[@]}")
echo ${cleanup_jobid} > ${dvc_stage_name}.dvc_cleanup_jobid


if [[ "${DVC_SLURM_DVC_PUSH_ON_COMMIT}" == "YES" ]]; then
    push_jobid=$(sbatch --parsable --job-name "${dvc_slurm_push_name}" --dependency afterok:${commit_jobid},singleton \
    --nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")/sbatch_dvc_push.sh" "${dvc_stage_name}")
    echo ${push_jobid} > ${dvc_stage_name}.dvc_push_jobid # useful to figure out which push job (all named equally) commits this stage
    if [[ "${DVC_SLURM_DVC_OP_NO_HOLD}" != "YES" ]]; then  # YES is potentially unsafe, the user invoking this must be aware of pot race condition
        scontrol hold ${push_jobid}
        log "Put dvc push job ${push_jobid} on hold - use 'scontrol release ${push_jobid}' to selectively unblock it or '$(dirname $0)/slurm_jobs.sh release push' to unblock all push jobs."
    fi
    log "Submitted all jobs for stage ${dvc_stage_name} (stage: ${stage_jobid}, commit: ${commit_jobid} (on hold), push: ${push_jobid} (on hold), cleanup: ${cleanup_jobid})."
else # write push op to a script for delayed manual submission through sbatch (before stage termination or if DVC jobs keep being run)
    push_script="slurm_enqueue_dvc_push_${dvc_stage_name}.sh"
    echo """#!/usr/bin/env bash

set -euxo pipefail

cd "\$\(dirname "\$0"\)"
push_jobid=\$(sbatch --parsable --job-name "${dvc_slurm_push_name}" --dependency afterok:${commit_jobid},singleton \
--nodes 1 --ntasks 1 ${dvc_slurm_opts_dvc_job} "$(dirname "$0")"/sbatch_dvc_push.sh "${dvc_stage_name}")
echo \${push_jobid} > ${dvc_stage_name}.dvc_push_jobid # useful to figure out which push job (all named equally) commits this stage

""" > ${push_script}
    chmod u+x ${push_script}
    log "Submitted all jobs for stage ${dvc_stage_name} (stage: ${stage_jobid}, commit: ${commit_jobid} (on hold), cleanup: ${cleanup_jobid})."
    log "Submit push with ${push_script}."
fi

