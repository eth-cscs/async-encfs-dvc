#!/usr/bin/env bash

# Usage e.g. ./encfs_mount_and_run_v2.sh <encrypt-dir> <decrypt-dir> <log-file> <program-to-run> <arg-1> <arg-2> ...
# The <log-file> can contain the pattern {MPI_RANK} that is replaced at runtime

set -epm

SCRIPT_NAME="$(basename "$0")"
ENCFS_ROOT_ARG="$1"
MOUNT_DIR_ARG="$2"

log () {
    echo "${SCRIPT_NAME}[${ENCFS_ROOT_ARG}->${MOUNT_DIR_ARG}]: $1"
}

log_error () {
    log "$1"
    exit 1
}

[[ "$VERBOSE" == "YES" ]] && set -x

# This script is executed on each rank and starts after mounting in /tmp/encfs_$(id -u) a process
# Once the process exits, the directory is unmounted again

# mounting options (all options are a feature of FUSE itself, not of the implemented filesystem):
# -f --> foreground
# -s --> no threads
# -o max_write=1048576,big_writes --> allow writes > 4Kb (currently it is limited to 128Kb per write request, although max_write is set to 1024Kb)
# --nocache disables caches, needed if running on multiple nodes, since other nodes can modify the same file

# use path where user installed encfs
if [ -x "$(command -v encfs)" ]; then
    ENCFS_BIN=encfs
elif [ -d "${APPS}/UES/anfink/encfs" ]; then
    ENCFS_BIN="${APPS}/UES/anfink/encfs/bin/encfs"
elif [ -f "${ENCFS_INSTALL_DIR}/bin/encfs" ]; then
    ENCFS_BIN="${ENCFS_INSTALL_DIR}/bin/encfs"
else
    ENCFS_BIN="$(dirname "$0")/encfs/install/bin/encfs"
fi

if [[ ! -f "${ENCFS_BIN}" || ! -x "${ENCFS_BIN}" ]]; then
    log_error "Error: encfs-binary at ${ENCFS_BIN} is not an executable."
fi

# TODO: Can we use the dvc_root_encfs.yaml (or dvc_app.yaml) file directly as in launch.sh?
ENCFS_ROOT="$(realpath "$1")"
MOUNT_DIR="$(realpath "$2")"
LOG_FILE="$3"
shift 3

# Node-local synchronization file (mount-/unmount-barrier)
ENCFS_LOCAL_SYNC_FILE="${ENCFS_ROOT}/.$(basename "${MOUNT_DIR}")_$(hostname)_local_sync"
if [ -f ${ENCFS_LOCAL_SYNC_FILE} ]; then
    log_error "Error: Local sync file ${ENCFS_LOCAL_SYNC_FILE} already exists - exiting."
fi

set +x # avoid leaking password
PASSWORD="${ENCFS_PW}"
[[ -n "${ENCFS_PW_FILE}" ]] && PASSWORD=$(eval cat ${ENCFS_PW_FILE})
if [ -z "${PASSWORD}" ]; then
    log_error "Error: EncFS-password not set - exiting."
fi
[[ "$VERBOSE" == "YES" ]] && set -x

# mount on each node, but only on local rank 0 (each physical node has one local rank 0)
if [ -n "${SLURM_LOCALID}" ]; then
    MPI_RANK=${SLURM_PROCID}
    MPI_LOCAL_RANK=${SLURM_LOCALID}
    MPI_LOCAL_SIZE="$($(dirname "$0")/slurm_step_get_local_ntasks.py)"
elif [ -n "${OMPI_COMM_WORLD_LOCAL_RANK}" ]; then
    MPI_RANK=${OMPI_COMM_WORLD_RANK}
    MPI_LOCAL_RANK=${OMPI_COMM_WORLD_LOCAL_RANK}
    MPI_LOCAL_SIZE=${OMPI_COMM_WORLD_LOCAL_SIZE}
elif [ -n "${PMI_RANK}" ]; then
    MPI_RANK=${PMI_RANK}
    MPI_LOCAL_RANK=${PMI_RANK}
    MPI_LOCAL_SIZE=${PMI_SIZE}
elif [ -n "${PMIX_RANK}" ]; then
    MPI_RANK=${PMIX_RANK}
    MPI_LOCAL_RANK=${PMIX_RANK}
    MPI_LOCAL_SIZE=${PMIX_SIZE}
else
    log "Unable to determine local MPI rank - assuming to run in non-distributed mode (as a single process)."
    MPI_RANK=0
    MPI_LOCAL_RANK=0
    MPI_LOCAL_SIZE=1
fi

LOG_FILE="${LOG_FILE/\{MPI_RANK\}/"${MPI_RANK}"}"

if [[ ${MPI_LOCAL_RANK} == 0 ]]; then
    log "Rank ${MPI_RANK} on $(hostname): Running encfs-mount at ${MOUNT_DIR}."
    mount | grep "${MOUNT_DIR}" && "${ENCFS_BIN}" -u "${MOUNT_DIR}" && sleep 3 # should never be needed
    ls_encfs_root=$(ls -lh "${ENCFS_ROOT}")
    log "${ls_encfs_root}"
    rm -Rf "${MOUNT_DIR}"
    mkdir -p "${MOUNT_DIR}"
    set +x # do not leak the password in the log files!!! 
    echo ${PASSWORD} | "${ENCFS_BIN}" -o allow_root,max_write=1048576,big_writes --nocache -S "${ENCFS_ROOT}" "${MOUNT_DIR}"

    echo ${MPI_LOCAL_RANK} > ${ENCFS_LOCAL_SYNC_FILE}
    [[ -x "$(command -v fsync)" ]] && fsync ${ENCFS_LOCAL_SYNC_FILE} || true  # FIXME: fsync-utility-alternative?
    log "Rank ${MPI_RANK} on $(hostname): Successfully mounted encfs-dir at ${MOUNT_DIR} and wrote to sync-file ${ENCFS_LOCAL_SYNC_FILE} - starting encfs-job"
else
    log "Rank ${MPI_RANK} on $(hostname): Waiting for encfs-mount at ${MOUNT_DIR} (sync-file ${ENCFS_LOCAL_SYNC_FILE})."
    # all ranks should wait until encfs mounted
    while [ ! -f ${ENCFS_LOCAL_SYNC_FILE} ]; do # (while ! mount | grep "${MOUNT_DIR}" ; do is unsafe if previously mounted)
        #log "Rank ${MPI_RANK} on $(hostname): ls on sync-file ${ENCFS_LOCAL_SYNC_FILE}: $(ls $(dirname ${ENCFS_LOCAL_SYNC_FILE}))."
        sleep 1
    done
    log "Rank ${MPI_RANK} on $(hostname): Detected successful encfs-mount at ${MOUNT_DIR} - starting encfs-job."
fi

# execute command as it was passed as arguments to this script - allow failure and exit with the status
set +e
"$@" >> "${LOG_FILE}" 2>&1
RET=$?
set -e

if [[ $RET != 0 ]]; then
    log "Error: Rank ${MPI_RANK} on $(hostname) (local rank ${MPI_LOCAL_RANK}): Failed with return code ${RET}."
    # exit ${RET} after rm "${ENCFS_LOCAL_SYNC_FILE}" ?
else
    log "Rank ${MPI_RANK} on $(hostname): encfs-job completed."
fi

# wait for all ranks to unmount encfs
if [[ ${MPI_LOCAL_RANK} == 0 ]]; then
    if [[ ${RET} == 0 ]]; then # if successful wait for all ranks to complete, else directly unmount
        log "Rank ${MPI_RANK} on $(hostname): sync-file content is $(cat "${ENCFS_LOCAL_SYNC_FILE}") - entering wait-loop."
        while ! flock --nonblock ${ENCFS_LOCAL_SYNC_FILE}.lock -c "[ "$(cat "${ENCFS_LOCAL_SYNC_FILE}" | wc -l)" -eq "${MPI_LOCAL_SIZE}" ]"; do
            sleep 1
        done
        log "Rank ${MPI_RANK} on $(hostname): sync-file content is $(cat "${ENCFS_LOCAL_SYNC_FILE}") - all local ranks finished encfs-job, unmounting encfs."
    fi
    encfs_unmount=$("${ENCFS_BIN}" -u "${MOUNT_DIR}")
    log "${encfs_unmount}"
    rmdir "${MOUNT_DIR}"
    rm ${ENCFS_LOCAL_SYNC_FILE} ${ENCFS_LOCAL_SYNC_FILE}.lock
else
    while ! flock --nonblock ${ENCFS_LOCAL_SYNC_FILE}.lock -c "echo ${MPI_LOCAL_RANK} >> ${ENCFS_LOCAL_SYNC_FILE}; [[ -x "$(command -v fsync)" ]] && fsync ${ENCFS_LOCAL_SYNC_FILE} || true"; do  # FIXME: fsync-utility-alternative?
        sleep 1
    done
    while mount | grep "${MOUNT_DIR}" ; do
        # wait on all processors until the directory is cleanly unmounted (ensures that the umount operation on LOCAL_RANk==0 has finished)
        sleep 1
    done
fi

exit ${RET}
