#!/usr/bin/env bash

set -euo pipefail

# DVC SLURM job (e.g. commit or push) monitoring and control: show, put on hold, release, cancel them


### same as in slurm_enqueue.sh
SCRIPT_NAME="$(basename "$0")"
log () {
    echo "${SCRIPT_NAME}: $1"
}

log_error () {
    log "$1"
    exit 1
}

dvc_stage_from_dep () {
    echo "${1##*:}"
}

dvc_yaml_from_dep () {
    echo "${1%:*}"
}

dvc_root="$(dvc root)"

# Append dvc root to SLURM job ID (due to repo-level lock)
dvc_stage_slurm_prefix="dvc"
dvc_stage_slurm_suffix=$(python3 -c "import hashlib; print(hashlib.sha1(\"$(realpath "${dvc_root}")\".encode(\"utf-8\")).hexdigest()[:12])") # "$(realpath "${dvc_root}" | sha1sum | head -c 12)"
get_dvc_slurm_job_name () { # compute SLURM job name for DVC stage/commit in $1
  echo "${dvc_stage_slurm_prefix}_$(dvc_stage_from_dep "$1")_${dvc_stage_slurm_suffix}"
}


dvc_slurm_put_jobs_on_hold () {
    dvc_job_name="$(get_dvc_slurm_job_name op)"
    while IFS=',' read -r job_id job_command job_reason; do
        if [[ -n "${job_id}" && -n "${job_command}" && -n "${job_reason}" ]]; then
            read -r job_id <<<"${job_id}"
            read -ra job_command <<<"${job_command}"
            read -r job_reason <<<"${job_reason}"
            if [[ $(basename ${job_command[0]}) == sbatch_dvc_"$1".sh && "${job_reason}" != JobHeldUser ]]; then
                log "Warning: Potential race condition due to ${dvc_job_name}[$(basename "${job_command[0]}")] job pending (reason ${job_reason} != JobHeldUser) at ${job_id} (for $(dvc root)/.dvc/tmp/rwlock). Putting on hold (release using '$(dirname "$0")/dvc_slurm_jobs.sh release $1')."
                scontrol hold ${job_id} # or: scontrol update JobID=${job_id} StartTime=now+300  # for 5 min delay
            fi
        fi
    done <<<$(squeue -u ${USER} --name="${dvc_job_name}" --format="%.30A,%.200o,%.30r" --sort=-S -h -t PENDING)

    while IFS=',' read -r job_id job_command job_reason; do
        if [[ -n "${job_id}" && -n "${job_command}" && -n "${job_reason}" ]]; then
            read -r job_id <<<"${job_id}"
            read -ra job_command <<<"${job_command}"
            read -r job_reason <<<"${job_reason}"
            if [[ $(basename ${job_command[0]}) == sbatch_dvc_"$1".sh ]]; then
                log "Warning: Potential race condition due to ${dvc_job_name}[$(basename "${job_command[0]}")] job running (reason ${job_reason} != JobHeldUser) at ${job_id} (for $(dvc root)/.dvc/tmp/rwlock). Requeueing on hold (release using '$(dirname "$0")/dvc_slurm_jobs.sh release $1')."
                scontrol requeuehold ${job_id} # or: scontrol requeue ${job_id} && scontrol update JobID=${job_id} StartTime=now+300  # for 5 min dely
            fi
        fi
    done <<<$(squeue -u ${USER} --name="${dvc_job_name}" --format="%.30A,%.200o,%.30r" --sort=-S -h -t RUNNING)
    
    while IFS=',' read -r job_id job_command job_reason job_username; do
        if [[ -n "${job_id}" && -n "${job_command}" && -n "${job_reason}" && -n "${job_username}" ]]; then
            read -r job_id <<<"${job_id}"
            read -ra job_command <<<"${job_command}"
            read -r job_reason <<<"${job_reason}"
            read -r job_username <<<"${job_username}"
            if [[ $(basename ${job_command[0]}) == sbatch_dvc_"$1".sh ]]; then
                if [[ "${job_username}" != "${USER}" && "${job_reason}" != JobHeldUser && "${job_reason}" != "job requeued in held" ]]; then
                    log_error "Error: User ${job_username} has a job ${dvc_job_name}[$(basename "${job_command[0]}")] pending/running at ${job_id} in non-held/requeued state (reason ${job_reason}). Cannot hold/requeue all ${dvc_job_name}[$(basename "${job_command[0]}")] jobs - abort."
                fi
            fi
        fi
    done <<<$(squeue --name="${dvc_job_name}" --format="%.30A,%.200o,%.30r,%.30u" --sort=-S -h -t RUNNING)
}

dvc_slurm_release_jobs () {
    dvc_job_name="$(get_dvc_slurm_job_name op)"
    while IFS=',' read -r job_id job_command job_reason; do
        if [[ -n "${job_id}" && "${job_command}" && -n "${job_reason}" ]]; then
            read -r job_id <<<"${job_id}"
            read -ra job_command <<<"${job_command}"
            read -r job_reason <<<"${job_reason}"
            if [[ $(basename ${job_command[0]}) == sbatch_dvc_"$1".sh ]]; then
                log "Releasing job ${dvc_job_name}[$(basename "${job_command[0]}")] (reason ${job_reason}) at ${job_id}."
                scontrol release ${job_id}
            fi
        fi
    done <<<$(squeue -u ${USER} --name="${dvc_job_name}" --format="%.30A,%.200o,%.30r" --sort=-S -h)
}


dvc_slurm_show_jobs () {
    dvc_job_name="$(get_dvc_slurm_job_name ".*")"
    dvc_job_ids=()
    while IFS=',' read -r job_id job_name job_command; do
        if [[ -n "${job_id}" && "${job_command}" ]]; then
            read -r job_id <<<"${job_id}"
            read -r job_name <<<"${job_name}"
            read -ra job_command <<<"${job_command}"
            if [[ "${job_name}" =~ ${dvc_job_name} && $(basename ${job_command[0]}) == "sbatch_dvc_$1.sh" ]]; then
                dvc_job_ids+=(${job_id})
            fi
        fi
    done <<<$(squeue -u ${USER} --format="%.30A,%.200j,%.200o" --sort=-S -h)
    dvc_job_ids="$(printf ",%s" "${dvc_job_ids[@]}")"
    set -x
    squeue --job "${dvc_job_ids:1}" --format="%.15u %.15A %.20r %.50j %.150Z" --sort=-S 
}


dvc_slurm_cancel_jobs () {
    dvc_job_name="$(get_dvc_slurm_job_name ".*")"
    while IFS=',' read -r job_id job_name job_command; do
        if [[ -n "${job_id}" && "${job_command}" ]]; then
            read -r job_id <<<"${job_id}"
            read -r job_name <<<"${job_name}"
            read -ra job_command <<<"${job_command}"
            if [[ "${job_name}" =~ ${dvc_job_name} &&  $(basename ${job_command[0]}) == sbatch_dvc_"$1".sh ]]; then
                log "Cancelling job ${job_name}[$(basename "${job_command[0]}")] at ${job_id}."
                scancel ${job_id}
            fi
        fi
    done <<<$(squeue -u ${USER} --format="%.30A,%.200j,%.200o" --sort=-S -h)
}

if [[ $# -ne 2 ]]; then
    log_error "Error: Wrong number of parameters (expected 2: task and dvc-op/stage): '$@'"
fi

case $1 in
    hold)
        #set -x
        dvc_slurm_put_jobs_on_hold "$2"
        ;;
    release)
        #set -x
        dvc_slurm_release_jobs "$2"
        ;;
    show)
        #set -x
        dvc_slurm_show_jobs "$2"
        ;;
    cancel)
        #set -x
        dvc_slurm_cancel_jobs "$2"
        ;;
    *)
        echo "Unknown option '$1' (choose either hold, release [combined with a dvc operation such as commit, push, cleanup], or show, cancel [additionally with stage])"
        exit 1
        ;;
esac

