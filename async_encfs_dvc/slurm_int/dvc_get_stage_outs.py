#!/usr/bin/env python

# Return list of stage outputs of DVC stage in sys.argv[1]

import sys
import yaml

if ':' in sys.argv[1]:
    filename, stage_name = sys.argv[1].split(':')
else:
    filename = 'dvc.yaml'
    stage_name = sys.argv[1]

with open(filename) as f:
    dvc_yaml = yaml.load(f, Loader=yaml.FullLoader)

print('\n'.join([p for out in dvc_yaml['stages'][stage_name]['outs']
                   for p in (out if isinstance(out, dict) else [out])]), end='')

