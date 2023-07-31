# Command reference

## DVC repository management

**dvc_init_repo** - initialize a DVC repository with repository and stage policies

```shell
Usage: dvc_init_repo DVC_ROOT REPO_POLICY

Positional arguments:
  DVC_ROOT     Root directory of the DVC repository to create.
  REPO_POLICY  Can be either plain (unencrypted repository) or encfs (EncFS-encrypted directory).
```

**dvc_create_stage** - generate DVC stages from a YAML application description

```shell
Usage: dvc_create_stage [--help] --app-yaml APP_POLICY --stage STAGE --run_label RUN_LABEL [--var-name VAR_VALUE] [--show-opts]

The command is only valid when invoked from within a DVC repository.

Required arguments:
  APP_POLICY   The application policy file (YAML) to instantiate a DVC stage from. Must reference DVC repo and stage policy (YAML) in include section relative to DVC root directory and may use Jinja2 template expressions.

  STAGE        The particular stage in the APP_POLICY.stages to instantiate.

  RUN_LABEL    The suffix for the generated DVC stage name to distinguish different instantiations.

Optional arguments:
  --var-name VAR_VALUE
               Define the value of a variable used in the application or stage policy. Replace var-name by the actual name of the Jinja2 variable.

  --show-opts
               Show completion options for Jinja2 variables based on current layout of DVC repository.
```

A typical application policy starts out in a development setting as in the vision transformer example with

![app_policy_init](app_policy_init.svg)

and then add in container support (green) with

![app_policy_docker](app_policy_docker.svg)

and finally make use of SLURM (yellow). Note that `slurm_nodes` is a Jinja2 variable here and as such becomes a command line parameter of `dvc_create_stage` for this policy (e.g. use as `dvc_create_stage ... --slurm_nodes 4 ...`).

![app_policy_slurm](app_policy_slurm.svg)

The policy for encryption is set at the repo-level during initialization (the app policy is agnostic to encryption). It is possible to maintain different application policies to target different setups.

## EncFS

**encfs_launch** - mount a decrypted view of an EncFS-encrypted directory for inspection of the data in another terminal (not for use with SLURM)

```shell
Usage: encfs_launch [REPO_POLICY]

Requires encfs to be in the path or ENCFS_INSTALL_DIR set. Requires ENCFS_PW_FILE to point to the EncFS-password. 

Positional arguments:
  REPO_POLICY  Repo policy of EncFS-managed repository. Defaults to `.dvc_policies/repo/dvc_root.yaml`.
```

## SLURM

**dvc_scontrol** - an scontrol wrapper for monitoring and controlling asynchronous SLURM DVC stages

```shell
Usage: dvc_scontrol TASK DVC_JOB_TYPES

Positional arguments:
  TASK          Any of hold, release, show, cancel. The effect corresponds to that of scontrol on the selected DVC job types. Note that dvc_create_stage submits all SLURM jobs in hold state.
  DVC_JOB_TYPES Comma-separated list that can involve all of stage, commit, push, cleanup.
```

## Non user-facing, implementation-related commands

### EncFS

**encfs_mount_and_run** - mount a decrypted view of an encrypted directory with EncFS and run a command (e.g. with SLURM)


```shell
Usage: encfs_mount_and_run ENCRYPT_DIR MOUNT_TARGET LOG_FILE COMMAND [PARAMS...]

Requires encfs to be in the path or ENCFS_INSTALL_DIR set. Requires ENCFS_PW_FILE to point to the EncFS-password. 

Positional arguments:
  ENCRYPT_DIR           EncFS-encrypted directory.
  MOUNT_TARGET          Mount target for decrypted view
  LOG_FILE              Where to put logs of COMMAND (typically under MOUNT_TARGET)
  COMMAND [PARAMS...]   Command with parameters to run on decrypted view      
```

### SLURM

**slurm_enqueue.sh** - submit DVC stage as multiple sbatch jobs to the SLURM queue respecting DVC stage dependencies and already submitted DVC stages

```shell
Usage: slurm_enqueue.sh DVC_STAGE_NAME INST_APP_POLICY APP_STAGE COMMAND [PARAMS...]

Positional arguments:
  DVC_STAGE_NAME        Name of stage in dvc.yaml
  INST_APP_POLICY       Instantiated application policy
  APP_STAGE             Stage to run in instantiated application policy
  COMMAND [PARAMS...]   Command with parameters to run asynchronously with sbatch
```
