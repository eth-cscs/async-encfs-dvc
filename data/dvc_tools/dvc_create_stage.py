#!/usr/bin/env python

import argparse
import subprocess as sp
import yaml
import os
import sys
import hashlib
import socket
import getpass
import datetime
import re
import glob
import shutil
from jinja2 import Environment, BaseLoader, meta, StrictUndefined

# This script generates the dvc stage by running
# ```
#   dvc run --no-exec --name <stage-name> --deps <host-input-directory> \
#       --outs(-persist) <host-output-directory>/output <container-image>
# ```
# The execution can then later be done with `dvc repro -s --no-commit <stage-name>` and
# upon successful completion dvc commit (built into to the instantiated container scripts)

# Two different ways of launching this:
# - first assemble dvc_app.yaml (with completion suggestions), then DVC stage
# - directly generate DVC stage from existing dvc_app.yaml


def run_shell_cmd(command):
    return sp.run(command, shell=True, check=True, capture_output=True).stdout.decode('utf-8').rstrip('\n')


# 1. step: generate dvc_app.yaml by merging with includes and move to dvc_dir
def make_full_app_yaml(app_yaml_file, stage, default_run_label):
    """Parse dvc_app.yaml and assemble full app-yaml using include references"""

    cwd = os.getcwd()
    os.chdir(os.path.dirname(app_yaml_file))
    app_yaml_file = os.path.basename(app_yaml_file)

    tmp_full_app_yaml_file = default_run_label + '_' + app_yaml_file
    if os.path.exists(tmp_full_app_yaml_file):
        raise RuntimeError("Choose different filename than {} " 
                           "for temporarily storing full yaml".format(tmp_full_app_yaml_file))

    with open(app_yaml_file, 'r') as f:
        app_yaml_str = f.read().replace('*', '')  # to avoid YAML load failure due to unresolved anchors
        app_yaml = yaml.load(app_yaml_str, Loader=yaml.FullLoader)

        f.seek(0)
        yaml_nodes = []
        full_app_yaml_lines = []

        def parse_yaml_line(line):  # FIXME: handle multiline > |
            line_stripped = line.lstrip(' ')
            return line_stripped, len(line) - len(line_stripped), line_stripped.startswith('#') or line_stripped == '\n'

        line = f.readline()
        while line != "":
            line_stripped, indent, is_comment = parse_yaml_line(line)
            if is_comment:
                full_app_yaml_lines.append(line)
                line = f.readline()
            elif line_stripped.startswith('- '):  # node is a list item
                assert indent == 2 * len(yaml_nodes)  # is a nested node
                while is_comment or indent >= 2 * len(yaml_nodes):  # ...don't recurse into lists, just copy them
                    full_app_yaml_lines.append(line)
                    line = f.readline()
                    _, indent, is_comment = parse_yaml_line(line)
            else:  # is a dict
                node_name = None
                for pattern in [r"^([\w-]+):", r"^\"(.+)\":", r"^\'(.+)\':"]:
                    match = re.search(pattern, line_stripped)
                    if match is not None:
                        node_name = match.group(1)
                        break
                if node_name is None:
                    raise RuntimeError("Could not read dict name in YAML line " + line)

                if indent == 2 * len(yaml_nodes):  # nested node
                    yaml_nodes.append(node_name)
                else:
                    yaml_nodes = yaml_nodes[:indent//2]
                    yaml_nodes.append(node_name)
                # skip unnecessary stages
                if len(yaml_nodes) == 3 and yaml_nodes[:2] == ['app', 'stages']:
                    if yaml_nodes[2] == stage:
                        full_app_yaml_lines.append(line)
                    line = f.readline()
                    _, indent, is_comment = parse_yaml_line(line)
                    while is_comment or indent >= 2 * len(yaml_nodes):
                        if yaml_nodes[2] == stage:
                            full_app_yaml_lines.append(line)
                        line = f.readline()
                        _, indent, is_comment = parse_yaml_line(line)
                # skip unnecessary includes
                elif len(yaml_nodes) == 2 and yaml_nodes[:1] == ['include'] and \
                    not(yaml_nodes[1].startswith('dvc_') or yaml_nodes[1] == app_yaml['app']['stages'][stage]['type']):
                    line = f.readline()
                    _, indent, is_comment = parse_yaml_line(line)
                    while is_comment or indent >= 2 * len(yaml_nodes):
                        line = f.readline()
                        _, indent, is_comment = parse_yaml_line(line)
                else:
                    full_app_yaml_lines.append(line)
                    line = f.readline()

    with open(tmp_full_app_yaml_file, 'w') as f:
        f.writelines(full_app_yaml_lines)


    with open(tmp_full_app_yaml_file, 'r') as f:
        app_yaml_str = f.read().replace('*', '')  # to avoid YAML load failure due to unresolved anchors
        app_yaml = yaml.load(app_yaml_str, Loader=yaml.FullLoader)

    # Previous version without YAML parsing
    #append_to_app_yaml_cmd = f"cp {app_yaml_file} {tmp_full_app_yaml_file} && " + \
    append_to_app_yaml_cmd = " && ".join([f"cat {app_yaml_include} >> {tmp_full_app_yaml_file}"
                                          for app_yaml_include in app_yaml['include'].values()])
    sp.run(append_to_app_yaml_cmd, shell=True, check=True)

    tmp_full_app_yaml_file = os.path.abspath(tmp_full_app_yaml_file)
    os.chdir(cwd)

    return tmp_full_app_yaml_file


# 2. step: Find all Jinja2 template variables in dvc_app.yaml, parse args and substitute
def load_full_app_yaml(filename, load_orig_dvc_root=False):
    with open(filename, 'r') as f:
        full_app_yaml = yaml.load(f, Loader=yaml.FullLoader)

    # Fix dvc root path
    if load_orig_dvc_root:
        yaml_filename = run_shell_cmd(f"echo \"{full_app_yaml['original']['file']}\"")
    else:
        yaml_filename = filename
    full_app_yaml['host_data']['dvc_root'] = \
        os.path.realpath(os.path.join(os.path.dirname(yaml_filename),
                                      os.path.dirname(full_app_yaml['include']['dvc_root']),
                                      full_app_yaml['host_data']['dvc_root']))
    return full_app_yaml, full_app_yaml['host_data']['dvc_root']


env = Environment(loader=BaseLoader())
def find_undeclared_variables(template_key, template):
    if isinstance(template, list):
        return {v: [dict(key=template_key, value=template)]
                for el in template
                for v in meta.find_undeclared_variables(env.parse(el))}
    else:
        return {v: [dict(key=template_key, value=template)]
                for v in meta.find_undeclared_variables(env.parse(template))}


def visit_yaml_undeclared_variables(tree_key, yaml_tree): # TODO: document this function
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
def parse_stage_args_and_substitute(full_app_yaml_template_file, default_run_label):

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
                             f"(options from {app_yaml_file}: {list(full_app_yaml['app']['stages'].keys())} )")
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
                occ_joined_paths = [os.path.join(*[os.path.join(*el) if isinstance(el, list) else el for el in occ['value']])
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
        if app_arg not in ['app_yaml', 'stage', 'run_label']:
            if f"--{app_arg.replace('_','-')}" in sys.argv:
                occ_joined_paths = [os.path.join(*[os.path.join(*el) if isinstance(el, list) else el for el in occ['value']])
                                    for occ in occurrences]

                parser.add_argument(f"--{app_arg.replace('_','-')}", type=str,
                                    help=f"app parameter used in {', '.join(occ_joined_paths)}")
            else:
                print(f"Warning: app argument --{app_arg.replace('_','-')} not set "
                      f"(using Jinja2 default in app YAML if not --strict-mode).")

    if '--help' in sys.argv or '--show-opts' in sys.argv:
        os.remove(full_app_yaml_template_file)  # full app-yaml file no longer required

    args = parser.parse_args()

    if args.show_opts: # do not substitute params, but show completion options
        # Only show options for command completion, don't generate stage actually (could be put in different module)
        def get_stage_args_dependencies(stage_args):
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

        for k in stage_args:
            if k in fixed_args:
                for other_k in stage_args_top_order:
                    if other_k != k:
                        stage_args_top_order[other_k].discard(k)
                    else:
                        stage_args_top_order[other_k] = set()

        stage_option_completions = dict()
        for stage_arg, occurrences in stage_args.items():
            if stage_arg in fixed_args or stage_arg in ['run_label']:
                continue

            if stage_arg in stage_args_top_order and len(stage_args_top_order[stage_arg]) > 0: # first fix dependency
                continue

            # May need to use encfs-mount resolution here in the future
            data_mount = full_app_yaml['host_data']['mount']['data']['origin']

            occ_joined_paths = [os.path.join(data_mount, *[os.path.join(*el) if isinstance(el, list) else el for el in occ['value']])
                                for occ in occurrences]

            # find common ancestor path, glob path, read with re.search and suggestions
            occ_joined_glob, occ_joined_regex = \
                sorted([(get_expanded_path_template(occ_path, {k: '*' if k not in fixed_args else fixed_args[k] for k in stage_args.keys()}),  # FIXME: can this be replaced by get_expanded_path?
                         get_expanded_path_template(occ_path, {k: r'(?P<' + k + r'>[\.\w-]+/?)' if k not in fixed_args else fixed_args[k] for k in stage_args.keys()}))
                        for occ_path in occ_joined_paths], reverse=True)[0]
            stage_option_candidates = []

            occ_joined_pattern = re.compile(occ_joined_regex)
            glob_search_path = os.path.join(host_dvc_root, occ_joined_glob)
            occ_joined_glob_matches = glob.glob(glob_search_path)
            occ_joined_glob_matches.sort(key=lambda file: os.path.getmtime(file), reverse=True)

            for glob_result in occ_joined_glob_matches:
                glob_result_relative = os.path.relpath(glob_result, host_dvc_root)
                occ_joined_matches = re.match(occ_joined_pattern, glob_result_relative)
                if stage_arg in occ_joined_matches.groupdict():
                    stage_option_candidates.append(occ_joined_matches[stage_arg])

            stage_option_completions[stage_arg] = dict(search_path=glob_search_path, candidates=stage_option_candidates)

        if len(stage_option_completions) > 0:
            print(f"### Completion options for stage arguments to dvc_create_stage.py ##")
            for stage_arg, completions in stage_option_completions.items():
                completions_str = '\n  '.join(completions['candidates'])
                print(f"Options for --{stage_arg.replace('_','-')} "
                      f"(glob search path {os.path.relpath(completions['search_path'], host_dvc_root)}):\n  " +
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


# 3. step: Assemble dvc-run command from rendered dvc_app.yaml
def create_dvc_stage(full_app_yaml_file, args, load_orig_dvc_root):
    # Change to host dvc root path to evaluate paths relative to it subsequently
    full_app_yaml, host_dvc_root = load_full_app_yaml(full_app_yaml_file, load_orig_dvc_root)
    os.chdir(host_dvc_root)

    # check input files are available and output root exists/is not populated
    stage_def = full_app_yaml[full_app_yaml['app']['stages'][args.stage]['type']]
    stage_label = f"{full_app_yaml['app']['name'].replace('/','_')}_{args.stage}"
    stage_name = f"{stage_label}_{full_app_yaml['original']['run_label']}"

    # Working directory of dvc run (e.g. <output_dep>/.. in ML stages), move rendered dvc_app.yaml there
    dvc_dir = get_validated_path([full_app_yaml['host_data']['dvc_config']] + stage_def['dvc'], is_input=False)
    os.makedirs(dvc_dir)
    shutil.move(full_app_yaml_file, os.path.join(dvc_dir, os.path.basename(args.app_yaml)))

    # Accumulate dvc run command, starting with host (-> encfs) -> container (runtime) mount mappings
    mounts = dict()
    for mount_name, mount_config in full_app_yaml['host_data']['mount'].items():
        if full_app_yaml['app']['container_engine'] != 'none':
            assert mount_name in full_app_yaml['container_data']['mount']
        if mount_config['type'] == 'plain':
            mounts[mount_name] = {'origin': mount_config['origin'],
                                  'host': mount_config['origin']}
        elif mount_config['type'] == 'encfs':
            if mount_name != 'data':
                raise RuntimeError("Error: currently only allowing 'data' mount of type 'encfs'.")
            encfs_root_dir = mount_config['origin']
            encfs_mounted_dir = None
            encfs_mounted_dir_suffix = stage_name + '_' + \
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
        # Could rename mounts[mount_name]['container'] -> mounts[mount_name]['runtime']
        if full_app_yaml['app']['container_engine'] == 'none':
            if os.path.isabs(mounts[mount_name]['host']):
                mounts[mount_name]['container'] = mounts[mount_name]['host']
            else:
                mounts[mount_name]['container'] = os.path.relpath(mounts[mount_name]['host'], dvc_dir)
        else:
            mounts[mount_name]['container'] = full_app_yaml['container_data']['mount'][mount_name]

    stage_data_deps = dict()
    for data_flow in ['input', 'output']:
        stage_data_deps[data_flow] = []
        for el in stage_def[data_flow]:
            stage_data_deps[data_flow].append(
                dict(host_stage_data=get_validated_path([mounts['data']['origin']] +
                                                        stage_def[data_flow][el]['stage_data'],
                                                        is_input=data_flow == 'input'),
                     host_mounted_stage_data=get_expanded_path([mounts['data']['host']] +
                                                               stage_def[data_flow][el]['stage_data']),
                     container_stage_data=get_expanded_path([mounts['data']['container']] +
                                                            stage_def[data_flow][el]['stage_data']),
                     command_line_options={opt: [mounts['data']['container']] + val
                                           for opt, val in stage_def[data_flow][el]['command_line_options'].items()}))

    # container-command
    def mount_cmd(mount_dir, is_host):
        if is_host:
            mount_dir = mount_dir if os.path.isabs(mount_dir) \
                else f"\$(realpath {os.path.relpath(mount_dir, dvc_dir)})"
        return "\\\"{}\\\"".format(mount_dir)

    if full_app_yaml['app']['container_engine'] == 'none':
        container_command = "bash -c"
    elif full_app_yaml['app']['container_engine'] == 'docker':
        container_engine_opts = full_app_yaml['app'].get('container_opts', {}) # dropped -u \$(id -u \${USER}):\$(id -g \${USER}) ' + \
        container_command = 'docker run --rm ' + \
                          ' '.join([f"-v {mount_cmd(v['host'], is_host=True)}:{mount_cmd(v['container'], is_host=False)}"
                                    for v in mounts.values()]) + ' ' + \
                          ' '.join([f"{k} {v}" for k, v in container_engine_opts.items()]) + \
                          f" --entrypoint bash {full_app_yaml['app']['image']} -c"
    elif full_app_yaml['app']['container_engine'] == 'sarus':
        # Andreas' SARUS_ARGS=env skipped (env could be set in extra wrapping script, cf. encfs_mount_and_run_v2.sh)
        container_engine_opts = full_app_yaml['app'].get('container_opts', {})
        container_command = 'sarus run ' + \
                          ' '.join([f"--mount=type=bind,source={mount_cmd(v['host'], is_host=True)},"
                                    f"destination={mount_cmd(v['container'], is_host=False)}"
                                    for v in mounts.values()]) + ' ' + \
                          ' '.join([f"{k} {v}" for k, v in container_engine_opts.items()]) + \
                          f" --entrypoint bash {full_app_yaml['app']['image']} -c"
    else:
        raise RuntimeError(f"Unsupported container engine {full_app_yaml['app']['container_engine']}")

    dvc_utils_rel_to_dvc_dir = os.path.relpath(sys.path[0], os.path.join(host_dvc_root, dvc_dir))

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

        # Could also use dvc_root_encfs.yaml directly as arg to encfs_mount_and_run_v2.sh (cf. launch.sh)
        encfs_command = f"{os.path.join(dvc_utils_rel_to_dvc_dir, 'encfs_scripts/encfs_mount_and_run_v2.sh')} " \
                        f"{encfs_root_dir} {encfs_mounted_dir} {encfs_log_file}"

        # Wrap container command into encfs-mount
        container_command = f"{encfs_command} {container_command}"

    # script to execute (path composed with code_root)
    script = get_expanded_path(full_app_yaml['app']['stages'][args.stage]['script'])

    # SLURM-/MPI-command
    using_slurm = 'slurm_opts' in full_app_yaml['app']['stages'][args.stage]
    if using_slurm:
        # Submits DVC stage and commit jobs that complete asynchronously, hence always use
        #   dvc repro --no-commit <stage-name>
        # to execute this stage. Checks all data dependencies to be ready beforehand and will
        # not submit if SLURM stage job already running/about to be committed.
        # FIXME: probably erroneous path to slurm_scripts
        container_command = f"{os.path.join(dvc_utils_rel_to_dvc_dir, 'slurm_scripts/slurm_enqueue.sh')} " \
                            f"{stage_name} {os.path.basename(args.app_yaml)} {args.stage} {container_command}"
    else:
        if 'mpi_opts' in full_app_yaml['app']['stages'][args.stage]:
            mpi_exec = full_app_yaml['app']['stages'][args.stage].get('mpi_exec', 'mpiexec')
            mpi_opts = ' '.join([f"{k} {v}" for k, v in full_app_yaml['app']['stages'][args.stage]['mpi_opts'].items()])
            mpi_command = f"{mpi_exec} {mpi_opts}"
            script = f"time {mpi_command} {script}"  # TODO: make call to time optional
            # container_command = f"{mpi_command} {container_command}"
        else:
            print("Not using SLURM or MPI in this DVC stage.")

    # script commandline options
    def get_expanded_options(opts, sep=" "):
        """Flatten values of YAML options dict and return as string"""
        expanded_options = [(opt, get_expanded_path(vals)) for (opt, vals) in opts.items()]
        return " ".join(f"{opt}{sep}{val}" for opt, val in expanded_options)

    stage_command_line_options = dict()
    for data_flow in ['input', 'output']:
        for el in stage_data_deps[data_flow]:
            stage_command_line_options.update(el['command_line_options'])

    # Do not compose extra_command_line_options with dvc_root as should be code deps, etc. (data deps caught in stages)
    command_line_options = get_expanded_options(stage_command_line_options) + " " +\
                           get_expanded_options(full_app_yaml['app']['stages'][args.stage]['extra_command_line_options'])


    commit_sha = run_shell_cmd("git rev-parse HEAD")
    git_root = run_shell_cmd("git rev-parse --show-toplevel")

    os.chdir(dvc_dir)

    host_stage_rel_input_deps  = [os.path.relpath(data_dep['host_stage_data'], dvc_dir)
                                  for data_dep in stage_data_deps['input']]
    host_stage_rel_output_deps = [os.path.relpath(data_dep['host_stage_data'], dvc_dir)
                                  for data_dep in stage_data_deps['output']]

    if using_encfs:
        host_stage_rel_output_deps.append('output')  # unencrypted log files with encfs

    for stage_output_dep in host_stage_rel_output_deps:
        os.makedirs(stage_output_dep)

    out_log_file = f"output/stage_out.log"  # can alternatively be done by appending to command

    print(f"Writing DVC stage to {os.path.relpath(os.getcwd(), host_dvc_root)}")
    if using_encfs:
        print(f"Using encfs - don't forget to set ENCFS_PW_FILE/ENCFS_INSTALL_DIR when running "
              f"\'dvc repro{' --no-commit' if using_slurm else ''}\'.")

    stage_create_command = os.path.relpath(sys.argv[0], git_root) + ' ' + ' '.join(sys.argv[1:])
    sp.run(f"dvc run --no-exec --name {stage_name} "
           f"{' '.join(['--deps {}'.format(dep) for dep in host_stage_rel_input_deps])} " 
           f"{' '.join([('--outs-persist ' if using_slurm else '--outs ') + dep for dep in host_stage_rel_output_deps])} "
           f"--desc \"Generated with {stage_create_command} at commit {commit_sha}\" "
           f"\"set -o pipefail; mkdir -p {' '.join(host_stage_rel_output_deps)} && "
           f"{container_command} \\\"{script} {command_line_options}\\\" 2>&1 | tee {out_log_file}\" ",
           shell=True, check=True)
    # TODO: mkdir host_stage_rel_output_deps only when not using slurm (as already integrated in dvc_run_sbatch (could be moved out again, though))


if __name__ == '__main__':
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
        args = parse_stage_args_and_substitute(tmp_full_app_yaml_file, default_run_label)
        # 3. step: Assemble dvc-run command from rendered dvc_app.yaml
        create_dvc_stage(full_app_yaml_file=tmp_full_app_yaml_file, args=args, load_orig_dvc_root=False)
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument("--app-yaml", type=str, required=True,
                            help="DVC stage generation configuration file")
        parser.add_argument("--stage", type=str, required=True,
                            help=f"DVC stage to run under app/stages in app-yaml")
        args = parser.parse_args()
        # 3. step: Assemble dvc-run command from rendered dvc_app.yaml
        create_dvc_stage(full_app_yaml_file=args.app_yaml, args=args, load_orig_dvc_root=True)

