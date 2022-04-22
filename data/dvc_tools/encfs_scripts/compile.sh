#!/bin/bash

set -exuo pipefail

cd $(realpath $(dirname $0))/encfs

mkdir -p build install

# Run on host
ENCFS_INSTALL_DIR=$(realpath install)
cd build && \
  cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${ENCFS_INSTALL_DIR} .. && \
  make VERBOSE=1 install

echo "encfs installed at ${ENCFS_INSTALL_DIR} (set export ENCFS_INSTALL_DIR=${ENCFS_INSTALL_DIR})."
