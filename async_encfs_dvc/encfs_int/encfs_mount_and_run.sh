#!/usr/bin/env bash

set -epm

[[ "$CUSTOM_ENV_VERBOSE" == "YES" ]] && set -x

# This script is executed on each rank and starts after mounting in /tmp/encfs_$(id -u) a process
# Once the process exits, the directory is unmounted again

# mounting options (all options are a feature of FUSE itself, not of the implemented filesystem):
# -f --> foreground
# -s --> no threads
# -o max_write=1048576,big_writes --> allow writes > 4Kb (currently it is limited to 128Kb per write request, although max_write is set to 1024Kb)
# --nocache disables caches, needed if running on multiple nodes, since other nodes can modify the same file

# use path where user installed encfs
ENCFSBIN="${APPS}/UES/anfink/encfs/bin/encfs"
MOUNTDIR="/tmp/encfs_$(id -u)"

set +x # avoid leaking password
PASSWORD="${CUSTOM_ENV_ENCFS_PW}"
[[ -n "${CUSTOM_ENV_ENCFS_PW_FILE}" ]] && PASSWORD=$(eval cat ${CUSTOM_ENV_ENCFS_PW_FILE})
[[ "$CUSTOM_ENV_VERBOSE" == "YES" ]] && set -x

# mount on each node, but only on local rank 0 (each physical node has one local rank 0)
if [[ ${SLURM_LOCALID} == 0 ]]; then
    mount | grep "${MOUNTDIR}" && "${ENCFSBIN}" -u "${MOUNTDIR}" && sleep 3
    ls -lh "${ENCFS_ROOT}"
    rm -Rf "${MOUNTDIR}"
    mkdir -p "${MOUNTDIR}"
    set +x # do not leak the password in the log files!!! 
    echo ${PASSWORD} | "${ENCFSBIN}" -o allow_root,max_write=1048576,big_writes --nocache -S "${ENCFS_ROOT}" "${MOUNTDIR}"
fi

# wait on all ranks until 
while ! mount | grep "${MOUNTDIR}" ; do
    sleep 1
done

# execute command as it was passed as arguments to this script - allow failure and exit with the status
set +e
"$@"
RET=$?
set -e

if [[ ${SLURM_LOCALID} == 0 ]]; then
    "${ENCFSBIN}" -u "${MOUNTDIR}"
fi

exit ${RET}
