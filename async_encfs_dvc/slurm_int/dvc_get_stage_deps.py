#!/usr/bin/env python

# Return list of stage dependencies of DVC stage sys.argv[1] in this directory (dvc.yaml)

import sys
import subprocess as sp
import pydot

assert ':' not in sys.argv[1]  # else process with abspath

dvc_dag_dot = sp.run(f"dvc dag --dot {sys.argv[1]}",  # requires DVC rwlock to be available
                     shell=True, capture_output=True).stdout.decode('utf-8')
graph = pydot.graph_from_dot_data(dvc_dag_dot)[0]

deps = []
for edge in graph.get_edges():
    if edge.get_destination().strip('"') == sys.argv[1]:
        deps.append(edge.get_source().strip('"'))
print('\n'.join(deps), end='')
