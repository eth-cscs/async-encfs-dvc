#!/usr/bin/env python3

import os
import re
import socket

SLURM_STEP_NODELIST = os.environ['SLURM_STEP_NODELIST']  # "nid0[2285-2289,2718-2723,5883-5890,7672-7679]" # "nid0[4278-4279],nid04280"
SLURM_STEP_TASKS_PER_NODE = os.environ['SLURM_STEP_TASKS_PER_NODE']  # "2(x21),1(x6)" # "2(x2),1"
hostname = socket.gethostname()

# parse step node list
node_list = []
node_list_str = SLURM_STEP_NODELIST
while len(node_list_str) > 0:
    match = re.search(r"^([^\[]+,|[^\[]+$)", node_list_str)
    if match is not None:
        single_node = match.group(1)
        node_list.append(single_node)
        node_list_str = node_list_str[len(single_node):].lstrip(',')
    else:
        match = re.search(r"^(.*)\[(.*)\].*", node_list_str)
        node_list_prefix = match.group(1)
        node_list_postfix = match.group(2)
        node_list_str = node_list_str[len(node_list_prefix) + len(node_list_postfix) + 2:].lstrip(',')
        for postfix in node_list_postfix.split(','):
            if '-' in postfix:
                begin, end = postfix.split('-')
                for node in range(int(begin), int(end) + 1):
                    node_list.append(node_list_prefix + str(node))
            else:
                node_list.append(node_list_prefix + postfix)

# parse step number of tasks list
tasks_per_node = []
for tasks_per_node_group in SLURM_STEP_TASKS_PER_NODE.split(','):
    if 'x' in tasks_per_node_group:
        match = re.search(r"(\d+)\(x(\d+)\)", tasks_per_node_group)
        tasks_per_node += [match.group(1) for i in range(int(match.group(2)))]
    else:
        tasks_per_node.append(tasks_per_node_group)

assert len(node_list) == len(tasks_per_node)

# output number of tasks on local host
for node, ntasks in zip(node_list, tasks_per_node):
    if hostname == node:
        print(ntasks, end='')
        exit(0)

raise RuntimeError("Could not find " + hostname + " in nodes " + ', '.join(node_list) + \
                   ' with number of tasks ' + ', '.join(tasks_per_node) + '.')

