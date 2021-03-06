#!/bin/bash

set -euxo pipefail

if [[ "$1" =~ .yaml ]]; then
    encfs_dirs=()
    while IFS= read -r line; do
        echo ${line}
        encfs_dirs+=("${line}")
    done <<< "$("$(dirname "$0")"/encfs_get_mount_config.py "$1")"
    if [[ ${#encfs_dirs[@]} -ne 2 ]]; then
        echo "Error: Found faulty encfs config with dirs ${encfs_dirs[*]}."
    fi
    DVC_ENCRYPT_DIR="$(eval echo "${encfs_dirs[0]}")"
    DVC_DECRYPT_DIR="$(eval echo "${encfs_dirs[1]}")"
else
    DVC_ROOT_DIR=$(realpath "$1")
    DVC_ENCRYPT_DIR=${DVC_ROOT_DIR}/encrypt

    if [[ "$(hostname)" =~ "daint" || "$(hostname)" =~ "nid" ]]; then
        DVC_DECRYPT_DIR="/tmp/encfs_$(id -u)"
        echo "On Piz Daint using ${DVC_DECRYPT_DIR} as decrypted (working) directory."
    else
        DVC_DECRYPT_DIR=${DVC_ROOT_DIR}/decrypt
        echo "On $(localhost) using ${DVC_DECRYPT_DIR} as decrypted (working) directory."
    fi
fi

mkdir -p "${DVC_DECRYPT_DIR}"

if [ -x "$(command -v encfs)" ]; then
    ENCFS_BIN=encfs
elif [[ ! -z "${APPS+x}" && -d "${APPS}/UES/anfink/encfs" ]]; then
    ENCFS_BIN="${APPS}/UES/anfink/encfs/bin/encfs"
elif [[ ! -z "${ENCFS_INSTALL_DIR+x}" && -f "${ENCFS_INSTALL_DIR}/bin/encfs" ]]; then
    ENCFS_BIN="${ENCFS_INSTALL_DIR}/bin/encfs"
else
    ENCFS_BIN="$(dirname "$0")/encfs/install/bin/encfs"
fi

set +x
[[ -n "${ENCFS_PW_FILE}" ]] && ENCFS_PW=$(eval cat ${ENCFS_PW_FILE})

echo "Launching encfs for single-node operation - do not use this with SLURM!"
# with a newer version of docker and libfuse allow_root must be set, otherwise decrypt cannot be mounted inside a container
echo ${ENCFS_PW} | ${ENCFS_BIN} -o allow_root,max_write=1048576,big_writes -S -f "${DVC_ENCRYPT_DIR}" "${DVC_DECRYPT_DIR}"
