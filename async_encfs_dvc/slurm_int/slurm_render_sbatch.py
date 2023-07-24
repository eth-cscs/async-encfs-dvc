#!/usr/bin/env python

# Render SLURM sbatch script template with environment options from app-yaml policy

import os
import sys
import yaml
from jinja2 import Environment, BaseLoader, meta, StrictUndefined
from async_encfs_dvc import slurm_int

assert len(sys.argv) == 5
dvc_app_yaml_filename = sys.argv[1]
stage_type = sys.argv[2]
slurm_job_type = sys.argv[3]
assert slurm_job_type in ['stage'] # 'commit', 'push', 'cleanup' could be supported analogously
dvc_stage_name = sys.argv[4]

with open(dvc_app_yaml_filename) as f:
    dvc_app_yaml = yaml.load(f, Loader=yaml.FullLoader)

if 'slurm_opts' in dvc_app_yaml['app']['stages'][stage_type]:
    job_env = dvc_app_yaml['app']['stages'][stage_type]['slurm_opts'].get(f"{slurm_job_type}_env", '')
    assert type(job_env) is str

with open(os.path.join(slurm_int.__path__[0], f"sbatch_dvc_{slurm_job_type}.sh"), 'r+') as f:
    sbatch_template = f.read()
    render_env = Environment(loader=BaseLoader())
    sbatch_script = render_env.from_string(sbatch_template) \
                              .render({f"slurm_{slurm_job_type}_env": job_env})

with open(f"sbatch_dvc_{slurm_job_type}_{dvc_stage_name}.sh", 'w') as sbatch_file:
    sbatch_file.write(sbatch_script)
