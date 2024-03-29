#!/usr/bin/env python3

"""Generate DVC stage from a parameterized app-policy in YAML that is instantiated with commandline arguments.

Two different ways of launching this:
- first instantiate dvc_app.yaml (use '--show-opts' for completion suggestions), then generate DVC stage
- directly generate DVC stage from instantiated dvc_app.yaml

Based on dvc_app.yaml this script generates a DVC stage by running the equivalent of
```
  dvc stage add --name <stage-name> --deps <host-input-directory> \
      --outs(-persist) <host-output-directory>/output ... (<slurm-command>/<container-command>/<encfs-command>)
```
The execution can then later be done with 'dvc repro <stage-name>' (use '--no-commit --no-lock' with SLURM, and
upon successful completion 'dvc commit').
"""

import argparse
import subprocess as sp
import os
import sys
import hashlib
import socket
import getpass
import datetime
import re
import glob
import shutil
import yaml
from jinja2 import Environment, BaseLoader, meta, StrictUndefined
from dvc.repo import Repo
import async_encfs_dvc


def run_shell_cmd(command):
    return sp.run(command, shell=True, check=True, capture_output=True).stdout.decode('utf-8').rstrip('\n')


def dvc_root():
    """Get DVC root directory or throw exception if not in a DVC repo"""

    dvc_root_sp = sp.run("dvc root", shell=True, check=True, stdout=sp.PIPE)
    return dvc_root_sp.stdout.decode().strip('\n')


def filter_yaml_parse_events(events, keys):
    """Get YAML subsection (keys: list of mapping keys)"""

    assert len(keys) > 0
    assert isinstance(events, list)

    keys.insert(0, None)
    arg_key = keys[-1]
    arg_stack = keys[:-1]

    last_key = None
    stack = []
    inside_section = False
    section_key = None
    section_events = []

    stack_structure = []
    stack_next_scalar_is_mapping_key = []

    for i, e in enumerate(events):
        if inside_section:
            section_events.append(e)

        if isinstance(e, yaml.SequenceStartEvent) or \
            isinstance(e, yaml.MappingStartEvent):
            stack.append(last_key)
            if len(stack_structure) > 0 and isinstance(stack_structure[-1], yaml.MappingStartEvent):
                stack_next_scalar_is_mapping_key[-1] = not stack_next_scalar_is_mapping_key[-1]

            stack_structure.append(e)
            stack_next_scalar_is_mapping_key.append(isinstance(e, yaml.MappingStartEvent))  # sequences in keys not supported

        elif isinstance(e, yaml.SequenceEndEvent) or \
            isinstance(e, yaml.MappingEndEvent):
            last_key = stack.pop()
            stack_structure.pop()
            stack_next_scalar_is_mapping_key.pop()

            if stack == arg_stack and last_key == arg_key:
                inside_section = False

        elif isinstance(e, yaml.ScalarEvent):
            if stack_next_scalar_is_mapping_key[-1]:  # only match in mappings, not sequences
                last_key = e.value

                if stack == arg_stack and last_key == arg_key:
                    section_key = e
                    index = i+1
                    next_event = events[index]
                    while isinstance(next_event, yaml.AliasEvent):
                        index += 1
                        next_event = events[index]

                    if isinstance(next_event, yaml.ScalarEvent):  # assuming to be in a mapping
                        section_events.append(next_event)  # only key-value pair
                    else:
                        inside_section = True  # nested data structure
            
            if isinstance(stack_structure[-1], yaml.MappingStartEvent):
                stack_next_scalar_is_mapping_key[-1] = not stack_next_scalar_is_mapping_key[-1]

    return section_key, section_events


def filter_and_load_yaml_parse_events(events, keys):
    _, filtered_events = filter_yaml_parse_events(events, keys)
    return yaml.load(yaml.emit(events[:2] + filtered_events + events[-2:]), Loader=yaml.FullLoader)


def isspace_or_empty(string):
    return len(string) == 0 or string.isspace()


def find_parent_excluding_children_from_yaml_parse_events(events, parent_keys, children_keys_to_keep):
    if len(events) == 0:
        return []

    lines = events[0].start_mark.buffer.split('\n')

    _, parent_events = filter_yaml_parse_events(events, parent_keys)
    parent_start_line = parent_events[0].start_mark.line
    parent_end_line = parent_events[-1].end_mark.line
    if not isspace_or_empty(lines[parent_events[-1].end_mark.line][parent_events[-1].end_mark.column:]):
        parent_end_line -= 1

    children_events = sorted([filter_yaml_parse_events(events[:2] + parent_events + events[-2:], [child_key_to_keep])
                              for child_key_to_keep in children_keys_to_keep],
                             key=lambda evs: evs[0].start_mark.pointer)

    intervals = [parent_start_line]
    for child_key_event, child_value_events in children_events:
        child_before_start_line = child_key_event.start_mark.line - 1
        child_past_end_line = child_value_events[-1].end_mark.line
        if not isspace_or_empty(lines[child_value_events[-1].end_mark.line][:child_value_events[-1].end_mark.column]):
            child_past_end_line += 1

        intervals.append(child_before_start_line)
        intervals.append(child_past_end_line)
    intervals.append(parent_end_line)

    return [(intervals[2*i], intervals[2*i + 1]) for i in range(len(intervals)//2)]


# 1. step: generate dvc_app.yaml by merging with includes and move to dvc_dir
def make_full_app_yaml(app_yaml_file, stage, default_run_label):
    """Parse dvc_app.yaml and assemble full app-yaml using include references"""

    dvc_root_rel_to_app_yaml = os.path.relpath(dvc_root(),
                                               os.path.dirname(app_yaml_file))

    cwd = os.getcwd()
    os.chdir(os.path.dirname(app_yaml_file))
    app_yaml_file = os.path.basename(app_yaml_file)

    tmp_full_app_yaml_file = default_run_label + '_' + app_yaml_file
    if os.path.exists(tmp_full_app_yaml_file):
        raise RuntimeError("Choose different filename than {} "
                           "for temporarily storing full yaml".format(tmp_full_app_yaml_file))

    with open(app_yaml_file, 'r') as f:

        # parse YAML sections to assemble full document (loading will fail due to unresolved anchors)
        events = list(yaml.parse(f.read()))
        app_yaml_stage_type = filter_and_load_yaml_parse_events(events, ['app', 'stages', stage, 'type'])
        app_yaml_includes = filter_and_load_yaml_parse_events(events, ['include'])

        # find stage lines to delete
        stage_lines_to_filter = find_parent_excluding_children_from_yaml_parse_events(events, ['app', 'stages'], [stage])

        # find include lines to delete
        include_lines_to_filter = find_parent_excluding_children_from_yaml_parse_events(events, ['include'], ['dvc_root', app_yaml_stage_type])

        lines_to_filter = sorted(filter(lambda interval: interval[0] <= interval[1],
                                        stage_lines_to_filter + include_lines_to_filter))

        f.seek(0)
        app_yaml_lines = f.readlines()

        if len(lines_to_filter) == 0:
            filtered_app_yaml_lines = app_yaml_lines
        else:
            filtered_app_yaml_lines = app_yaml_lines[0:lines_to_filter[0][0]]
            for prev_lines_to_filter, next_lines_to_filter in zip(lines_to_filter[:-1], lines_to_filter[1:]):
                filtered_app_yaml_lines += app_yaml_lines[prev_lines_to_filter[1]+1:next_lines_to_filter[0]]
            filtered_app_yaml_lines += app_yaml_lines[lines_to_filter[-1][1]+1:]

    with open(tmp_full_app_yaml_file, 'w') as f:
        f.writelines(filtered_app_yaml_lines)

        for app_yaml_include in [app_yaml_includes['dvc_root'],
                                 app_yaml_includes[app_yaml_stage_type]]:
            with open(os.path.join(dvc_root_rel_to_app_yaml, app_yaml_include), 'r') as policy:
                f.write('\n' + policy.read())

    tmp_full_app_yaml_file = os.path.abspath(tmp_full_app_yaml_file)
    os.chdir(cwd)

    return tmp_full_app_yaml_file


# 2. step: Find all Jinja2 template variables in dvc_app.yaml, parse args and substitute
def load_full_app_yaml(filename, load_orig_dvc_root=False):
    with open(filename, 'r') as f:
        full_app_yaml = yaml.load(f, Loader=yaml.FullLoader)  # TODO: consider Jinja2-render before yaml.load everywhere

    # Fix dvc root path
    if load_orig_dvc_root:
        yaml_filename = run_shell_cmd(f"echo \"{full_app_yaml['original']['file']}\"")
    else:
        yaml_filename = filename
    yaml_file_dir = os.path.dirname(yaml_filename)
    full_app_yaml['host_data']['dvc_root'] = \
        os.path.realpath(os.path.join(yaml_file_dir,
                                      os.path.relpath(dvc_root(), yaml_file_dir),
                                      os.path.dirname(full_app_yaml['include']['dvc_root']),
                                      full_app_yaml['host_data']['dvc_root']))
    return full_app_yaml, os.path.normpath(full_app_yaml['host_data']['dvc_root'])


env = Environment(loader=BaseLoader())
def find_undeclared_variables(template_key, template):
    if isinstance(template, list):
        return {v: [dict(key=template_key, value=template)]
                for el in template
                for v in meta.find_undeclared_variables(env.parse(el))}
    else:
        return {v: [dict(key=template_key, value=template)]
                for v in meta.find_undeclared_variables(env.parse(template))}


def visit_yaml_undeclared_variables(tree_key, yaml_tree):  # TODO: document this function
    # YAML visitor
    undeclared_variables = dict()
    for k, v in yaml_tree.items():
        full_key = [*tree_key, k]
        if isinstance(v, dict):
            undeclared_variables_update = visit_yaml_undeclared_variables(full_key, v)
        else:
            undeclared_variables_update = find_undeclared_variables(full_key, v)

        for k, v in undeclared_variables_update.items():
            if k in undeclared_variables:
                undeclared_variables[k].append(*v)
            else:
                undeclared_variables[k] = v

    return undeclared_variables


def get_expanded_path_template(template_filename, variables=None):
    """Flatten YAML filename path and substitute Jinja2 params (respecting empty variables)"""

    if isinstance(template_filename, list):
        template_filename = [get_expanded_path_template(filename, variables) for filename in template_filename]
        return os.path.join(*template_filename)
    else:
        return template_filename if variables is None else env.from_string(template_filename).render(variables)


def get_expanded_path(template_filename):
    """Flatten and resolve YAML filename path"""
    filename = get_expanded_path_template(template_filename)
    # The following is to resolve the filename path (abs/rel unchanged)
    if os.path.isabs(filename):
        return os.path.abspath(filename)
    else:
        return os.path.relpath(os.path.abspath(filename), os.getcwd())


def get_validated_path(yaml_filename, is_input=True):
    """For input paths check their existence, for output paths make sure they don't exist"""
    expanded_path = get_expanded_path(yaml_filename)
    if is_input and not os.path.exists(expanded_path):  # input path should exist
        dir_content = '\n' + '\n'.join(glob.glob(os.path.join(os.getcwd(), os.path.dirname(expanded_path), '*')))
        raise RuntimeError(
            f"input dep {expanded_path} not found - "
            f"filename options: {dir_content}")
    elif not is_input and os.path.exists(expanded_path):  # output path should not yet exist
        dir_content = '\n' + '\n'.join(glob.glob(os.path.join(os.getcwd(), os.path.dirname(expanded_path), '*')))
        raise RuntimeError(
            f"output path {expanded_path} already exists - "
            f"base path contains: {dir_content}")
    else:
        return expanded_path


# 2. step: Find all Jinja2 template variables in dvc_app.yaml, parse args and substitute
def parse_stage_args_and_substitute(full_app_yaml_template_file, stage, default_run_label):

    full_app_yaml, host_dvc_root = load_full_app_yaml(full_app_yaml_template_file)

    stage_type = full_app_yaml['app']['stages'][stage]['type']
    app_args = visit_yaml_undeclared_variables(['app', 'stages', stage], full_app_yaml['app']['stages'][stage])
    stage_args = visit_yaml_undeclared_variables([stage_type], full_app_yaml[stage_type])

    # parse_known_args might be useful for show-opts

    parser = argparse.ArgumentParser()

    parser.add_argument("--app-yaml", type=str, required=True,
                        help="DVC stage generation configuration file")
    parser.add_argument("--stage", type=str, required=True,
                        help=f"DVC stage to run under app/stages in app-yaml "
                             f"(options from {full_app_yaml_template_file}: {list(full_app_yaml['app']['stages'].keys())} )")
    parser.add_argument("--run-label", type=str, default=default_run_label,
                        help="Label (suffix) of DVC stage (defaults to <timestamp>_<hostname>)")
    parser.add_argument("--strict-mode", action='store_true',
                        help="Fail on undefined Jinja2 variables in app YAML file (disregarding defaults)")
    parser.add_argument("--show-opts", action='store_true',
                        help="Show options from stage definition yaml files for completing the current command")

    # stage options
    for stage_arg, occurrences in stage_args.items():
        if stage_arg not in ['app_yaml', 'stage', 'run_label']:
            if f"--{stage_arg.replace('_','-')}" in sys.argv:
                occ_joined_paths = [os.path.join(*[os.path.join(*el) if isinstance(el, list) else el
                                                   for el in occ['value']])
                                    for occ in occurrences]

                parser.add_argument(f"--{stage_arg.replace('_','-')}", type=str,
                                    help=f"{stage_type} parameter used in {', '.join(occ_joined_paths)}, "
                                         "use --show-opts to see options")
            elif '--show-opts' not in sys.argv:
                print(f"Warning: stage argument --{stage_arg.replace('_','-')} not set "
                      f"(using Jinja2 default in app YAML if not --strict-mode).")

    # app options (user-defined, e.g. for SLURM param substitution using
    # --<stage-type>-slurm-num-nodes/--<stage-type>-slurm-num-tasks)
    for app_arg, occurrences in app_args.items():
        # avoid duplicate declaration for args that were imported to stage definition with YAML anchors
        if app_arg not in ['app_yaml', 'stage', 'run_label'] and app_arg not in stage_args: 
            if f"--{app_arg.replace('_','-')}" in sys.argv:
                occ_joined_paths = [os.path.join(*[os.path.join(*el) if isinstance(el, list) else el
                                                   for el in occ['value']])
                                    for occ in occurrences]

                parser.add_argument(f"--{app_arg.replace('_','-')}", type=str,
                                    help=f"app parameter used in {', '.join(occ_joined_paths)}")
            else:
                print(f"Warning: app argument --{app_arg.replace('_','-')} not set "
                      f"(using Jinja2 default in app YAML if not --strict-mode).")

    if '--help' in sys.argv or '--show-opts' in sys.argv:
        os.remove(full_app_yaml_template_file)  # full app-yaml file no longer required

    args = parser.parse_args()

    if args.show_opts:  # do not substitute params, but show completion options

        # Only show options for command completion, don't generate stage actually (could be put in different module)
        def get_stage_args_dependencies(stage_args):  # returns mapping of stage args a -> b, where a is used in subset of keys b is used in
            stage_args_top_order = {k: set() for k in stage_args}
            stage_args_list = list(stage_args.keys())
            for stage_arg_1_ind, stage_arg_1 in enumerate(stage_args_list):
                stage_arg_1_key_set = set([tuple(el['key']) for el in stage_args[stage_arg_1]])
                for stage_arg_2 in stage_args_list[:stage_arg_1_ind]:
                    stage_arg_2_key_set = set([tuple(el['key']) for el in stage_args[stage_arg_2]])
                    if stage_arg_1_key_set.issuperset(stage_arg_2_key_set):
                        stage_args_top_order[stage_arg_2].add(stage_arg_1)
                    if stage_arg_1_key_set.issubset(stage_arg_2_key_set):
                        stage_args_top_order[stage_arg_1].add(stage_arg_2)
            return stage_args_top_order

        # stage options
        fixed_args = {k: v for k, v in vars(args).items() if v is not None}
        stage_args_top_order = get_stage_args_dependencies(stage_args)

        for k in stage_args:  # remove fixed args from dependency graph
            if k in fixed_args:
                for other_k in stage_args_top_order:
                    if other_k == k:
                        stage_args_top_order[other_k] = set()
                    else:
                        stage_args_top_order[other_k].discard(k)

        stage_option_completions = dict()
        for stage_arg, occurrences in stage_args.items():
            if stage_arg in fixed_args or stage_arg in ['run_label']:
                continue

            if stage_arg in stage_args_top_order and len(stage_args_top_order[stage_arg]) > 0:  # first fix dependency
                continue

            # May need to use encfs-mount resolution here in the future
            data_mount = full_app_yaml['host_data']['mount']['data']['origin']

            occ_joined_paths = sorted([os.path.relpath(os.path.join(data_mount, *[os.path.join(*el)
                                                                                  if isinstance(el, list)
                                                                                  else el for el in occ['value']]), '.')
                                       for occ in occurrences])
            
            occ_joined_paths = [  # only search in least specific paths
                 occ_path for i, occ_path in enumerate(occ_joined_paths)
                 if not any(occ_path.startswith(other) for other in occ_joined_paths[:i])
            ]

            stage_option_candidates = []
            glob_search_paths = []
            # find common ancestor path, glob path, read with re.search and suggestions
            for occ_joined_glob, occ_joined_regex in \
                sorted([(get_expanded_path_template(occ_path, {k: '*' if k not in fixed_args else fixed_args[k]
                                                               for k in stage_args.keys()}),  # cf. get_expanded_path
                         get_expanded_path_template(occ_path, {k: r'(?P<' + k + r'>[\.\w-]+/?)' if k not in fixed_args
                                                               else fixed_args[k] for k in stage_args.keys()}))
                        for occ_path in occ_joined_paths], reverse=True):

                stage_option_candidates.append(set())

                occ_joined_pattern = re.compile(occ_joined_regex)
                glob_search_path = os.path.join(host_dvc_root, occ_joined_glob)
                glob_search_paths.append(glob_search_path)
                occ_joined_glob_matches = glob.glob(glob_search_path)
                occ_joined_glob_matches.sort(key=lambda file: os.path.getmtime(file), reverse=True)

                for glob_result in occ_joined_glob_matches:
                    glob_result_relative = glob_result.removeprefix(host_dvc_root)[1:]
                    occ_joined_matches = re.match(occ_joined_pattern, glob_result_relative)
                    if stage_arg in occ_joined_matches.groupdict():
                        candidate = occ_joined_matches[stage_arg]
                        stage_option_candidates[-1].add(candidate)

            stage_option_candidates = set.intersection(*stage_option_candidates)

            stage_option_completions[stage_arg] = dict(search_path=glob_search_paths, candidates=stage_option_candidates)

        if len(stage_option_completions) > 0:
            print(f"### Completion options for stage arguments to dvc_create_stage ###")
            for stage_arg, completions in stage_option_completions.items():
                glob_search_paths_str = ', '.join([p.removeprefix(host_dvc_root)[1:]
                                                   for p in completions['search_path']])
                completions_str = '\n  '.join(completions['candidates'])
                print(f"Options for `--{stage_arg.replace('_','-')}` "
                      f"(glob search paths: {glob_search_paths_str}):\n  " +
                      completions_str)
        else:
            print(f"### Stage arguments are complete ##")
        exit(0)

    # Rewrite dvc_app.yaml using Jinja2 variable substitution
    full_app_yaml_jinja_vars = vars(args)
    with open(full_app_yaml_template_file, 'r+') as f:
        tmp_full_app_yaml = f.read()
        if args.strict_mode:
            render_env = Environment(loader=BaseLoader(), undefined=StrictUndefined)
        else:
            render_env = Environment(loader=BaseLoader())
        rendered_full_app_yaml = render_env.from_string(tmp_full_app_yaml).render(full_app_yaml_jinja_vars)
        f.seek(0)
        f.write(rendered_full_app_yaml)
        f.write(f"\n\noriginal:\n"
                f"  file: \"$(dvc root)/{os.path.relpath(full_app_yaml_template_file, host_dvc_root)}\""
                f"  # source of this DVC app stage configuration\n"
                f"  run_label: \"{args.run_label}\""
                f"  # original run_label used\n\n")
        f.truncate()
    return args


def render_cli_opts(opts, sep=' '):
    return ' '.join([f"{k}{sep}{v}" if v is not None else k for k, v in opts.items()])


# 3. step: Assemble dvc-run command from rendered dvc_app.yaml
def create_dvc_stage(full_app_yaml_file, args, load_orig_dvc_root):
    # Change to host dvc root path to evaluate paths relative to it subsequently
    full_app_yaml, host_dvc_root = load_full_app_yaml(full_app_yaml_file, load_orig_dvc_root)
    os.chdir(host_dvc_root)

    # check input files are available and output root exists/is not populated
    stage_def = full_app_yaml[full_app_yaml['app']['stages'][args.stage]['type']]
    stage_label = f"{full_app_yaml['app']['name'].replace('/','_')}_{args.stage}"
    stage_name = f"{stage_label}_{full_app_yaml['original']['run_label']}"

    # Working directory of dvc stage add (e.g. <output_dep>/.. in ML stages), move rendered dvc_app.yaml there
    dvc_dir = get_validated_path([full_app_yaml['host_data']['dvc_config']] + stage_def['dvc'], is_input=False)
    os.makedirs(dvc_dir)
    full_app_yaml_basename = os.path.basename(args.app_yaml)
    shutil.move(full_app_yaml_file, os.path.join(dvc_dir, full_app_yaml_basename))

    # Accumulate dvc stage add command, starting with host (-> encfs) -> container (runtime) mount mappings
    mounts = dict()
    for mount_name, mount_config in full_app_yaml['host_data']['mount'].items():
        # TODO: integrate this with encfs_int.mount_config

        if mount_config['type'] == 'plain':
            mounts[mount_name] = {'origin': mount_config['origin'],
                                  'host': mount_config['origin']}
        elif mount_config['type'] == 'encfs':
            if mount_name != 'data':
                raise RuntimeError("Error: currently only allowing 'data' mount of type 'encfs'.")
            encfs_root_dir = mount_config['origin']
            encfs_mounted_dir = None
            encfs_mounted_dir_suffix = stage_name + '_' + \
                                       hashlib.sha1(dvc_dir
                                                    .encode("utf-8")).hexdigest()[:12] + '_' + \
                                       hashlib.sha1(full_app_yaml['host_data']['dvc_root']
                                                    .encode("utf-8")).hexdigest()[:12]
            for target in mount_config['custom_target']:
                if len([machine for machine in target['machine'] if re.search(machine, socket.gethostname())]) > 0:
                    encfs_mounted_dir = target['target'] + '_' + encfs_mounted_dir_suffix
                    break
            if encfs_mounted_dir is None:
                encfs_mounted_dir = mount_config['default_target'] + '_' + encfs_mounted_dir_suffix

            mounts[mount_name] = {'origin': encfs_root_dir,
                                  'host': encfs_mounted_dir}
        else:
            raise RuntimeError(f"Unsupported mount config {mount_name} of type {mount_config['type']}.")

    for mount_name in mounts:
        # Container mount target required for container engines
        if 'container_engine' in full_app_yaml['app'] and full_app_yaml['app']['container_engine'] != 'none':
            assert mount_name in full_app_yaml['container_data']['mount']

        # Could rename mounts[mount_name]['container'] -> mounts[mount_name]['runtime']
        if 'container_engine' not in full_app_yaml['app'] or full_app_yaml['app']['container_engine'] == 'none':
            if os.path.isabs(mounts[mount_name]['host']):
                mounts[mount_name]['container'] = mounts[mount_name]['host']
            else:
                mounts[mount_name]['container'] = os.path.relpath(mounts[mount_name]['host'], dvc_dir)
        else:
            mounts[mount_name]['container'] = full_app_yaml['container_data']['mount'][mount_name]

    stage_data_deps = dict()
    for data_flow in ['input', 'output']:
        stage_data_deps[data_flow] = []
        for el in stage_def.get(data_flow, dict()):
            stage_data_deps[data_flow].append(
                dict(host_stage_data=get_validated_path([mounts['data']['origin']] +
                                                        stage_def[data_flow][el]['stage_data'],
                                                        is_input=data_flow == 'input'),
                     host_mounted_stage_data=get_expanded_path([mounts['data']['host']] +
                                                               stage_def[data_flow][el]['stage_data']),
                     container_stage_data=get_expanded_path([mounts['data']['container']] +
                                                            stage_def[data_flow][el]['stage_data']),
                     command_line_options={opt: [mounts['data']['container']] + val
                                           for opt, val in
                                           stage_def[data_flow][el].get('command_line_options', dict()).items()}))

    # container-command
    def mount_cmd(mount_dir, is_host):
        if is_host:
            mount_dir = mount_dir if os.path.isabs(mount_dir) \
                else f"\$(realpath {os.path.relpath(mount_dir, dvc_dir)})"
        return "\\\"{}\\\"".format(mount_dir)

    if 'container_engine' not in full_app_yaml['app'] or full_app_yaml['app']['container_engine'] == 'none':
        container_command = "bash -c"
    elif full_app_yaml['app']['container_engine'] == 'docker':
        container_engine_opts = full_app_yaml['app'].get('container_opts', {})
        # dropped -u \$(id -u \${USER}):\$(id -g \${USER})
        container_command = 'docker run --rm ' + \
            ' '.join([f"-v {mount_cmd(v['host'], is_host=True)}:{mount_cmd(v['container'], is_host=False)}"
                      for v in mounts.values()]) + ' ' + \
            render_cli_opts(container_engine_opts) + \
            f" --entrypoint bash {full_app_yaml['app']['image']} -c"
    elif full_app_yaml['app']['container_engine'] == 'sarus':
        # Andreas' SARUS_ARGS=env skipped (env could be set in extra wrapping script, cf. encfs_mount_and_run)
        container_engine_opts = full_app_yaml['app'].get('container_opts', {})
        container_command = 'sarus run ' + \
            ' '.join([f"--mount=type=bind,source={mount_cmd(v['host'], is_host=True)},"
                      f"destination={mount_cmd(v['container'], is_host=False)}"
                      for v in mounts.values()]) + ' ' + \
            render_cli_opts(container_engine_opts) + \
            f" --entrypoint bash {full_app_yaml['app']['image']} -c"
    else:
        raise RuntimeError(f"Unsupported container engine {full_app_yaml['app']['container_engine']}")

    # encfs-command
    using_encfs = full_app_yaml['host_data']['mount']['data']['type'] == 'encfs'
    if using_encfs:  # Requires ENCFS_PW_FILE and (potentially) ENCFS_INSTALL_DIR as env variables
        encfs_root_dir = os.path.join(os.path.relpath('.', dvc_dir), mounts['data']['origin'])
        if os.path.isabs(mounts['data']['host']):
            encfs_mounted_dir = mounts['data']['host']
        else:
            encfs_mounted_dir = os.path.relpath(mounts['data']['host'], dvc_dir)

        encfs_log_file = os.path.relpath(
            os.path.join(stage_data_deps['output'][0]['host_mounted_stage_data'], "encfs_out_{MPI_RANK}.log"), dvc_dir)

        # Could also use dvc_root_encfs.yaml directly as arg to encfs_mount_and_run (cf. encfs_launch)
        encfs_command = f"encfs_mount_and_run " + " ".join([os.path.normpath(p) for p in
                                                            [encfs_root_dir, encfs_mounted_dir, encfs_log_file]])

        # Wrap container command into encfs-mount
        container_command = f"{encfs_command} {container_command}"

    # script to execute (path composed with code_root)
    script = get_expanded_path(full_app_yaml['app']['stages'][args.stage]['script'])

    # SLURM-/MPI-command
    using_slurm = 'slurm_opts' in full_app_yaml['app']['stages'][args.stage]
    if using_slurm:
        # Submits DVC stage and commit jobs that complete asynchronously, hence always use
        #   dvc repro --no-commit --no-lock <stage-name>
        # to execute this stage. Checks all data dependencies to be ready beforehand and will
        # not submit if SLURM stage job already running/about to be committed.
        container_command = f"slurm_enqueue.sh " \
                            f"{stage_name} {os.path.basename(args.app_yaml)} {args.stage} {container_command}"
    else:
        if 'mpi_opts' in full_app_yaml['app']['stages'][args.stage]:
            mpi_exec = full_app_yaml['app']['stages'][args.stage].get('mpi_exec', 'mpiexec')
            mpi_opts = render_cli_opts(full_app_yaml['app']['stages'][args.stage]['mpi_opts'])
            mpi_command = f"{mpi_exec} {mpi_opts}"
            script = f"time {mpi_command} {script}"  # TODO: make call to time optional
            # container_command = f"{mpi_command} {container_command}"
        else:
            print("Not using SLURM or MPI in this DVC stage.")

    os.chdir(dvc_dir)

    # script commandline options
    def get_expanded_options(opts, expand_paths, sep=" "):
        """Flatten values of YAML options dict and return as string"""
        expanded_options = [(opt,
                             get_expanded_path(vals) if expand_paths else
                             (os.path.join(*vals) if isinstance(vals, list) else vals))
                            for (opt, vals) in opts.items()]
        expanded_options_cmd = []
        for opt, val in expanded_options:
            if val is not None:
                expanded_options_cmd.append(f"{opt}{sep}{val}")
            else:
                expanded_options_cmd.append(opt)
        return " ".join(expanded_options_cmd)

    stage_command_line_options = dict()
    for data_flow in ['input', 'output']:
        for el in stage_data_deps[data_flow]:
            stage_command_line_options.update(el['command_line_options'])

    # Do not compose extra_command_line_options with dvc_root as should be code deps, etc. (data deps caught in stages)
    command_line_options = get_expanded_options(stage_command_line_options, expand_paths=True)
    extra_command_line_options = full_app_yaml['app']['stages'][args.stage].get('extra_command_line_options', None)
    if extra_command_line_options is not None:
        command_line_options += " " + get_expanded_options(extra_command_line_options, expand_paths=False)

    commit_sha = run_shell_cmd("git rev-parse HEAD")
    git_root = run_shell_cmd("git rev-parse --show-toplevel")

    host_stage_rel_input_deps  = [os.path.relpath(data_dep['host_stage_data'], dvc_dir)
                                  for data_dep in stage_data_deps['input']]
    host_stage_rel_output_deps = [os.path.relpath(data_dep['host_stage_data'], dvc_dir)
                                  for data_dep in stage_data_deps['output']]

    # deduplicate DVC paths (may occur due to logically separate dependencies tracked in same path)
    def deduplicate_paths(paths):
        unique_paths = []
        for p in paths:
            if p not in unique_paths:
                unique_paths.append(p)
        return unique_paths


    host_stage_rel_input_deps = deduplicate_paths(host_stage_rel_input_deps)
    host_stage_rel_output_deps = deduplicate_paths(host_stage_rel_output_deps)

    if using_encfs:
        host_stage_rel_output_deps.append('output')  # unencrypted log files with encfs

    # Create output directories (necessary for no-op stages that are never executed)
    for stage_output_dep in host_stage_rel_output_deps:
        os.makedirs(stage_output_dep)

    print(f"Writing DVC stage to {os.path.relpath(os.getcwd(), host_dvc_root)}")
    if using_encfs:
        print(f"Using encfs - don't forget to set ENCFS_PW_FILE/ENCFS_INSTALL_DIR when running "
              f"\'dvc repro{' --no-commit --no-lock' if using_slurm else ''}\'.")

    stage_create_command = os.path.relpath(sys.argv[0], git_root) + ' ' + ' '.join(sys.argv[1:])
    sp.run(f"dvc stage add --name {stage_name} "
           f"{' '.join(['--deps {}'.format(dep) for dep in host_stage_rel_input_deps])} " 
           f"{' '.join([('--outs-persist ' if using_slurm else '--outs ') + dep for dep in host_stage_rel_output_deps])} "
           f"--desc \"Generated with {stage_create_command} at commit {commit_sha}\" "
           f"\"dvc_cmd {stage_name} {container_command} \\\"{script} {command_line_options}\\\" \" ",
           shell=True, check=True)
    # mkdir host_stage_rel_output_deps only required when not using slurm (as already integrated in dvc_run_sbatch)

    # optionally freeze stage (manually executed stages, etc.)
    if full_app_yaml['app']['stages'][args.stage].get('frozen', False):
        print(f"Freezing stage for execution outside of DVC - run 'dvc commit {stage_name}' when outputs are done.")
        sp.run(f"dvc freeze {stage_name} ", shell=True, check=True)

    # if autostage is true add instantiated YAML to git
    if Repo().config['core']['autostage']:
       sp.run(f"git add {full_app_yaml_basename}", shell=True, check=True)
       print(f"Added `{full_app_yaml_basename}` to Git staging area.")


def main():
    app_yaml_argv_index = sys.argv.index('--app-yaml')
    if app_yaml_argv_index == -1:
        raise RuntimeError("Commandline option --app-yaml is required")
    else:
        app_yaml_file = sys.argv[app_yaml_argv_index + 1]

    stage_argv_index = sys.argv.index('--stage')
    if stage_argv_index == -1:
        raise RuntimeError("Commandline option --app-yaml is required")
    else:
        stage = sys.argv[stage_argv_index + 1]

    with open(app_yaml_file) as f:
        is_full_app_yaml = 'original:' in f.read()

    if not is_full_app_yaml:
        # create default run_label
        hostname = socket.gethostname()
        username = getpass.getuser()
        default_run_label = f"{datetime.datetime.now().strftime('%y-%m-%d_%H-%M-%S')}_{hostname}_{username}"

        # 1. step: generate dvc_app.yaml by merging with includes and move to dvc_dir
        tmp_full_app_yaml_file = make_full_app_yaml(app_yaml_file, stage, default_run_label)
        # 2. step: Find all Jinja2 template variables in dvc_app.yaml, parse args and substitute
        args = parse_stage_args_and_substitute(tmp_full_app_yaml_file, stage, default_run_label)
        # 3. step: Assemble dvc-run command from rendered dvc_app.yaml
        create_dvc_stage(full_app_yaml_file=tmp_full_app_yaml_file, args=args, load_orig_dvc_root=False)
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument("--app-yaml", type=str, required=True,
                            help="DVC stage generation configuration file")
        parser.add_argument("--stage", type=str, required=True,
                            help="DVC stage to run under app/stages in app-yaml")
        args = parser.parse_args()
        # 3. step: Assemble dvc-run command from rendered dvc_app.yaml
        create_dvc_stage(full_app_yaml_file=args.app_yaml, args=args, load_orig_dvc_root=True)


if __name__ == '__main__':
    main()
