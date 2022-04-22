#!/usr/bin/env python

# Get SLURM options from dvc stage sys.argv[2] in dvc_app.yaml at sys.argv[1] for --stage or --dvc job (sys.argv[3])

import sys
import os
import hashlib
import socket
import re
import yaml

assert len(sys.argv) == 2
dvc_root_encfs_filename = sys.argv[1]

with open(dvc_root_encfs_filename) as f:
    dvc_root_encfs = yaml.load(f, Loader=yaml.FullLoader)

# TODO: merge functionality with dvc_create_stage
host_dvc_root = os.path.join(os.path.dirname(dvc_root_encfs_filename),
                             dvc_root_encfs['host_data']['dvc_root'])

mount_config = dvc_root_encfs['host_data']['mount']['data']
assert mount_config['type'] == 'encfs'

encfs_root_dir = mount_config['origin']
encfs_mounted_dir = None
# encfs_mounted_dir_suffix = hashlib.sha1(os.path.abspath(host_dvc_root).encode("utf-8")).hexdigest()[:12]
hostname = socket.gethostname()
for target in mount_config['custom_target']:
    if len([machine for machine in target['machine'] if re.search(machine, hostname)]) > 0:
        encfs_mounted_dir = target['target']  # + '_' + encfs_mounted_dir_suffix
        break
if encfs_mounted_dir is None:
    encfs_mounted_dir = mount_config['default_target']  # + '_' + encfs_mounted_dir_suffix

print('\n'.join([os.path.join(host_dvc_root, d) for d in [encfs_root_dir, encfs_mounted_dir]]), end='')
