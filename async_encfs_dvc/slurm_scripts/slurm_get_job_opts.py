#!/usr/bin/env python

# Get SLURM options from dvc stage sys.argv[2] in dvc_app.yaml at sys.argv[1] for --stage or --dvc job (sys.argv[3])

import sys
import yaml

assert len(sys.argv) == 4
dvc_app_yaml_filename = sys.argv[1]
stage_type = sys.argv[2]
slurm_job_type = sys.argv[3][2:]
assert slurm_job_type in ['stage', 'dvc']  # get either stage or dvc SLURM options

with open(dvc_app_yaml_filename) as f:
    dvc_app_yaml = yaml.load(f, Loader=yaml.FullLoader)

if 'slurm_opts' in dvc_app_yaml['app']['stages'][stage_type]:
    opts = dvc_app_yaml['app']['stages'][stage_type]['slurm_opts'].get('all', {})
    opts.update(dvc_app_yaml['app']['stages'][stage_type]['slurm_opts'].get(slurm_job_type, {}))
else:
    opts = {}


if slurm_job_type == 'stage':
    print(' '.join([f"{opt} {val}" for opt, val in opts.items()]), end='')
else:
    print(' '.join([f"{opt} {val}" for opt, val in opts.items()
                    if opt not in ['--nodes', '-N', '--ntasks', '-n']]), end='')
