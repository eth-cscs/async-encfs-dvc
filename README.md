# Data version control in privacy-preserving HPC workflows using DVC, EncFS, SLURM and Openstack Swift on castor.cscs.ch

This project applies infrastructure-as-code principles to [DVC](https://dvc.org) and combines it with [EncFS](https://github.com/vgough/encfs) and [SLURM](https://slurm.schedmd.com) to track results of scientific HPC workflows in a privacy-preserving manner and exchange them through the OpenStack Swift object storage at `castor.cscs.ch`.

The **core features** extending DVC include
* HPC cluster support: DVC stages (and their dependencies) can be executed asynchronously with SLURM (`dvc run/repro` submits a SLURM job, `dvc commit` is run upon completion of that job)
* privacy-preserving: DVC stages can use transparent encryption with [EncFS](https://github.com/vgough/encfs) so that no unencrypted data is persisted to storage or exchanged with DVC (see [further details](data/dvc_tools/encfs_scripts/README.md))
* container engine support: DVC stages can be run with Docker and [Sarus](https://github.com/eth-cscs/sarus), code-dependencies are tracked using Git-SHA-tagged container images which makes the stages fully re-executable
* infrastructure-as-code approach: DVC stages can be generated from a succinct definition of an application's execution environment in YAML by importing a set of reusable definitions encoding DVC repo structure and stage policies

These features are largely orthogonal, so can be used separately. They are exemplified on two demo applications, [app_ml](app_ml) for an ML application and [app_sim](app_sim) for a simulation. The main executables for these are
 * [training.py](app_ml/training.py) and [inference.py](app_ml/inference.py) for `app_ml` 
 * [simulation.sh](app_sim/simulation.sh) for `app_sim`.

The proposed setup does not make any assumptions on application data protocols in these executables/a corresponding workflow. Application protocols need to be managed at the application-level (i.e. the above executables) with its own versioning (which can be used, though, to structure the repository). One option for the above examples may be setting up a package in a folder `app_protocol` that is imported by both `app_ml` and `app_sim` and enables them to communicate. DVC as used here does not have a concept for application protocols, but only of dependencies between files (which makes it well-suited to work with unstructured data). The purpose of this project is to provide a base platform that eases tracking of data dependencies in complex workflows with strong data privacy needs.

For more background on data versioning with DVC stages, please consult the [documentation](https://dvc.org/doc/use-cases/versioning-data-and-model-files/tutorial#automating-capturing) on `dvc run` (`dvc exp` is currently not the main focus of this project, cf. reasons outlined [below](#synchronous-execution-of-dvc-experiments-with-slurm-using-a-centralized-controller)). Note that to version an application's output with the code that was used to produce it, we use Git-SHA-tagged container images in the command supplied to `dvc run`. This automatically catches all code-dependencies and makes DVC stages fully re-executable. This is in contrast to the documentation, i.e. we do not track code dependencies with the `-d` option in `dvc run`, we reserve this option for input data dependencies of the DVC stage.


# Usage

The core utility is [dvc_create_stage.py](data/dvc_tools/dvc_create_stage.py) that generates a DVC stage based on a concise definition of the application's runtime environment as well as DVC repo structure and stage policies. The app definition and stage policies can be parameterized allowing the user a certain flexibility, which is exposed through `dvc_create_stage.py`'s command line API. Besides that, the tool follows an infrastructure-as-code approach and the YAML usage is inspired by such tools (e.g. Ansible). 

Example applications are shown in [app_ml](app_ml/dvc_app.yaml) for an ML application and [app_sim](app_sim/dvc_app.yaml) for a simulation. Typical usage takes the form
```shell
dvc_create_stage.py --app-yaml app_ml/dvc_app.yaml --stage inference ... 
```
where the application to run is specified in `--app-yaml` and the application stage in `--stage`. The latter must correspond to an entry at `app > stages`, e.g. for `app_ml/dvc_app.yaml` `training` and `inference` are valid options. 

The `dvc_app.yaml` by itself, however, is not complete. Rather it has to be augmented with policies encoding the repository structure and DVC stage definitions located in [data/dvc_tools/dvc_defs](data/dvc_tools/dvc_defs). For each application stage in `dvc_app.yaml` a `type` is referenced in `dvc_app.yaml` and a corresponding stage definition imported (under `include`) that declares the stage's data dependencies and outputs as well as associated commandline parameters. For `app_ml/dvc_app.yaml` the imported definitions are [dvc_ml_training.yaml](data/dvc_tools/dvc_defs/stages/dvc_ml_training.yaml) and [dvc_ml_inference.yaml](data/dvc_tools/dvc_defs/stages/dvc_ml_inference.yaml). In addition, `dvc_app.yaml` also imports a DVC repo definition (under the `dvc_root` field) that specifies the top-level layout of a DVC-managed directory (as compared to the stage definition that specify the finer layout). In particular, there are examples of both a DVC repo with EncFS-encryption ([dvc_root_encfs.yaml](data/dvc_tools/dvc_defs/repos/dvc_root_encfs.yaml)) and without encryption ([dvc_root_plain.yaml](data/dvc_tools/dvc_defs/repos/dvc_root_plain.yaml)).
 
In a first step, `dvc_create_stage.py` processes the `include`s required by `--stage` (discarding all other entries `app > stages`). Note that the repo, stage and app definitions can contain YAML anchors and references as well as Jinja2 template variables. All of them are only resolved after the required `include`s are processed. 

In a second step, `dvc_create_stage.py` resolves all YAML anchors and substitutes the Jinja2 template variables and writes the resulting full stage definition to a file. The values for the Jinja2 variables can be set via the commandline (replace `_` by `-` for this purpose and use `--show-opts` for commandline completion suggestions). The Jinja2 template variables are the primary customization point for DVC stages generated with `dvc_create_stage.py`.

From the resulting full stage definition, `dvc_create_stage.py` then creates the actual DVC stage using `dvc run --no-exec ...`. This step can be performed on its own on just a full stage definition file later. Once the DVC stage is generated, it can be run using the familiar `dvc repro .../dvc.yaml` or `dvc repro --no-commit .../dvc.yaml` with SLURM. When using `EncFS`, make sure the `ENCFS_PW_FILE` and possibly also `ENCFS_INSTALL_DIR` are set in the environment.

The resulting DVC repository will be structured systematically along the following layout (without encryption)

```
$ tree
.
├── input_data
│   ├── original
│   │   ├── <app1>
│   │   │    └── <version>
│   │   │         └── <run-label>
...
│   │   └── <appN>
...
│   └── preprocessed
│       ├── <app1>
│       │    └── <version>
│       │         └── <etl-app>
│       │              └── <run-label>
...
│       └── <appN>
...
├── <app1>
│   └── <version>
│       ├── <stage_a>
│       │    └── <run-label>
│       └── <stage_b>
│            └── <run-label>
...
├── <appN>
│   └── <version>
...
└── output_data
    └── <target_format>
        ├── <app1>
...
        └── <appN>
```

For the `EncFS`-managed repository, stage data will be split into an `EncFS`-encrypted directory `encrypt` and an unencrypted directory `config` for DVC stage files and non-private meta-information. The repo structure below `encrypt` and `config` is identical.

The repo and stage definitions in [data/dvc_tools/dvc_defs](data/dvc_tools/dvc_defs) represent a starting point to be extended and customized in a project that builds on this.

## Asynchronous execution of DVC stages with SLURM

With SLURM, `dvc repro --no-commit` runs DVC stages asynchronously as SLURM jobs with `sbatch` directly from the command line of a SLURM job submission node, which can be a login node of a supercomputer or a dedicated, *short-lived* controller-node allocated with
```shell
$ salloc --job-name dvc_op_<repo-hash> --dependency singleton --nodes 1 ...
```
In particular, for each DVC stage a job is submitted for the actual application command (named `dvc_<stage-name>_<repo-hash>`), upon its successful completion a `dvc commit` job is executed, and upon stage failure a cleanup job. Optionally, a `dvc push` job (to a remote such as Castor) that runs after the `dvc commit` job can be submitted as well. The command `dvc repro --no-commit` returns when these jobs are successfully submitted to the SLURM queue. That is, the application has not yet executed and any of the data dependencies should not be edited before the application stage and commit jobs have completed asynchronously. 

DVC dependencies are respected using SLURM dependencies of the application jobs (using `dvc dag`). A potential conflict for the `$(dvc root).dvc/tmp/rwlock` that is acquired by many `dvc` commands (such as `repro`, `commit` and `push`) that fail if they cannot acquire it is in parts avoided by naming all `dvc commit` and `dvc push` SLURM jobs as `dvc_op_<repo-hash>` and only allowing a single of these to be running (per DVC repo) in SLURM. 

When submitting DVC SLURM stages with `dvc repro` (which also acquires this lock), it is the responsibility of the user that no `dvc commit` or `dvc push` jobs on the same DVC repo are already running concurrently in the background. As a first measure, it is recommended to have only a single user actively running jobs on a DVC repo. To display the status of `dvc` jobs, one can use [slurm_jobs.sh](data/dvc_tools/slurm_scripts/slurm_jobs.sh) with `show commit` or `show push`. If you needed to `dvc repro` (or another locking command such as `dvc status`), you can put a repo's `commit` and `push` jobs on hold/requeue them with `hold commit` and `hold push`. When finished with `dvc repro` these jobs can be unblocked with the `release` command (i.e. `release commit` and `release push`). To be able to run multiple `dvc` commands without interruption, `dvc commit` and `dvc push` jobs always submitted `hold` (unless `DVC_SLURM_DVC_OP_NO_HOLD=YES` is set in the `dvc repro` environment, e.g. when using the above `salloc`-command for a short-lived controller node). Thereby, the user has time to schedule multiple DVC pipelines (with `dvc repro`) before running `release commit` (and `release push`) to unblock these jobs on the repo.

In the `dvc repro` environment, generating the `dvc push` job that runs upon completion of `dvc commit` can be optionally enabled by setting `DVC_SLURM_PUSH_ON_COMMIT=YES`. Otherwise a script is generated in the `dvc.yaml` folder that allows to submit a corresponding SLURM `dvc push` job later respecting SLURM dependencies and the DVC lock constraint.


### Known pitfalls and limitations

To avoid unexpected behavior with asynchronously executed DVC SLURM stages, it is recommended to follow these points
* Only have a single user actively running jobs on a DVC repo. This avoids unintentional race conditions for the DVC lock and permission issues with SLURM job control commands that don't work across users.
* Do not launch a mix of SLURM stages and non-SLURM stages (running on the localhost) in a `dvc repro --no-commit` call on a SLURM cluster, only either or (there is currently no mechanism that checks this). SLURM stages are executed asynchronously (as SLURM jobs, after `dvc repro --no-commit` returned, only the job submission happens synchronously), whereas non-SLURM jobs require their inputs to be available when `dvc repro --no-commit` executes.
* running `dvc repro --no-commit` on a DAG that has already been partially executed but not committed will make DVC try to synchronously commit any un-/partially committed stages which can lead to high resource consumption on the local node. In such a case, please allocated a dedicated controller node with the above `salloc` command to re-run any failed/incompletely run `dvc commit` jobs on stages, where the application has successfully completed.
* Use [slurm_jobs.sh](data/dvc_tools/slurm_scripts/slurm_jobs.sh) with `show`, `hold`, `release` or `cancel` to display and control SLURM jobs. Do not run `dvc repro` concurrently with another locking `dvc` command (such as `dvc commit`, `dvc push` or `dvc status`) in the same DVC repo, rather run them sequentially (one after the other). These commands (independent of whether it's a SLURM job or not) will try to acquire the `$(dvc root).dvc/tmp/rwlock` and fail if unsuccessful (thus, needs to be restarted manually). With asynchronously committed/pushed SLURM stages, the risk of running concurrent `dvc` commands (e.g. `dvc commit` in one pipeline and `dvc repro` in another) competing for this lock is much higher than when these commands are run synchronously.
* Do not rely on the output of `dvc status` when executing asynchronous SLURM stages. `dvc repro` returns upon SLURM job submission believing that the stage has been completed (and correspondingly updating the `dvc.lock` file), when actually only the `dvc commit` job executed after the application job will commit the results (or the cleanup job remove them in case of failure). The actual status of asynchronous SLURM stages is tracked in `<stage-name>.<status>` files in the `dvc.yaml` folder, which represents a workaround for a missing feature in `dvc.lock` to track asynchronously completed stages (this would require a mechanism for setting up asynchronous stages, e.g. `dvc run --async <stage>` that is updated by `dvc repro` and (ideally) taken into account during DAG scheduling - which requires talking to the external scheduler - as well as by `dvc status` and a method to update their status such as `dvc commit --async <status> <stage>` as well as a method to clean up stale statuses such as `dvc gc --async`).

## Synchronous execution of DVC experiments with SLURM using a centralized controller

As an alternative to the above asynchronous execution of DVC stages, it is possible to execute them synchronously from a centralized controller node if they use [`sbatch --wait`](https://github.com/iterative/dvc/issues/1057#issuecomment-901367180) in the DVC command so that `sbatch` only returns upon completion (or failure) of the SLURM job. This can be useful to e.g. run DVC experiments managed with `dvc exp` queues. The [procedure](https://dvc.org/doc/user-guide/experiment-management) includes first defining experiments and filling up the queue using `dvc exp run --queue <stage>`, where `<stage>` must use `sbatch --wait ...` if it includes a SLURM job, and then running a SLURM job for the centralized controller, e.g. with

```shell
$ sbatch --job-name dvc_op_<repo-hash> --dependency singleton --time <max-time> --account <account> --constraint mc sbatch_dvc_exp_run.sh --run-all --jobs ...
```

where `sbatch_dvc_exp_run.sh` looks like

```shell
#!/bin/bash -l
#SBATCH --output=dvc_sbatch.dvc_exp_run.%j.out
#SBATCH --error=dvc_sbatch.dvc_exp_run.%j.err

set -euxo pipefail
echo "Running DVC experiments (must use `sbatch --wait` if SLURM job) controlled from ${SLURM_JOB_NAME}."
time srun --nodes 1 --ntasks 1 dvc exp run --verbose "$@"
```
or a corresponding `salloc` command (same parameters as for `sbatch` above) and running `dvc` commands manually on the allocated node. To maintain long-running sessions for both the `salloc` environment (to keep the SLURM job) and on the allocated node (to run `dvc` commands) [`tmux`](https://github.com/tmux/tmux/wiki) may be useful. From the controller node, DVC will then orchestrate the execution of all experiments. 

The upside of this approach is that the full DVC API can be used and SLURM stages can be mixed with non-SLURM stages (executing on the controller node). The downsides are having no possibility to interact with DVC while the controller job (i.e. all the experiments/application stages) is running (unless `dvc exp run --temp` is used, also cf. [new features](https://github.com/iterative/dvc/issues/7592) being developed), less parallelism in stage execution and potentially less efficient scheduling in SLURM due to submitting jobs only upon completion of their dependencies (i.e. DVC takes over dependency handling for SLURM). Also, the controller node may spend a lot of time idle (waiting for experiments to be scheduled and run to obtain stage results) and reach the maximum job time limit on some systems (24 h on Piz Daint) before its scheduled experiments finish. For these reasons, the above asynchronous DVC stage execution model is currently preferred. 

# Performance on Piz Daint and Castor

We use the `iterative_sim` benchmark [with](benchmarks/iterative_sim_encfs_benchmark.sh) and [without](benchmarks/iterative_sim_plain_benchmark.sh) `EncFS`, where `app_sim` is run with `Sarus` on 8 GPU nodes, 16 ranks with each rank writing its payload to the filesystem. The subsequent `dvc commit` and `dvc push` commands are run on a single multi-core node. On the `scratch` filesystem on Piz Daint, creating the 7 stages takes around 25 s and we obtain the following performance numbers with `EncFS`

| per-rank payload | aggregate payload | stage time (SLURM step) | dvc commit time (SLURM step) | dvc push time to Castor (SLURM step) |
| ----------------:| -----------------:| -----------------------:| ----------------------------:| ------------------------------------:|
|  1 GB            |    16 GB          |  0m 46.772s             |  0m 51.943s                  |   2m 22.111s                         |
|  2 GB            |    32 GB          |  1m  9.924s             |  1m 28.868s                  |   3m 55.135s                         |
|  4 GB            |    64 GB          |  2m 39.029s             |  3m  7.332s                  |   8m 26.389s                         |
|  8 GB            |   128 GB          |  4m 55.051s             |  6m 10.173s                  |  15m 18.366s                         |
| 16 GB            |   256 GB          |  9m 28.857s             | 11m 25.793s                  |  29m 48.568s                         |
| 32 GB            |   512 GB          | 17m  6.680s             | 22m 48.705s                  |  60m  2.022s                         |
| 64 GB            | 1.024 TB          | 32m 23.975s             | 45m 29.780s                  |  (> object size limit)               |

where `64 GB` exceeded the limit on the object file size in the last `dvc push` (when using HDF5 as an application protocol, using external links to split an HDF5 into multiple files each containing a dataset can alleviate this and avoid unnecessarily long `dvc commit` times for small changes, cf. [this discussion](https://github.com/iterative/dvc/discussions/6776)). When run without `EncFS`, we obtain the following results on Piz Daint

| per-rank payload | aggregate payload | stage time (SLURM step) | dvc commit time (SLURM step) |
| ----------------:| -----------------:| -----------------------:| ----------------------------:|
|  1 GB            |    16 GB          |  0m  6.024s             |   0m 54.967s                 |
|  2 GB            |    32 GB          |  0m  9.014s             |   1m 29.028s                 |
|  4 GB            |    64 GB          |  0m 16.560s             |   2m 48.102s                 |
|  8 GB            |   128 GB          |  0m 30.655s             |   5m 14.163s                 |
| 16 GB            |   256 GB          |  1m  7.828s             |  10m 25.876s                 |
| 32 GB            |   512 GB          |  1m 54.963s             |  22m 10.754s                 |
| 64 GB            | 1.024 TB          |  3m 31.399s             |  46m 46.014s                 |

Note that only one `dvc commit` or `dvc push` SLURM job can run per DVC repo at any time, while stages can run be concurrently as long as they are not DVC dependencies of one another. If `dvc commit` or `dvc push` are throughput-limiting steps, one can increase the performance by running disjoint pipelines in separate clones of the Git/DVC repo. To avoid redundant transfers of large files, it may be useful to synchronize over the local filesystem by adding a [local remote](https://dvc.org/doc/command-reference/remote#example-add-a-default-local-remote), e.g. with 
```shell
dvc remote add daint-local $SCRATCH/path/to/remote
```
and then 
```shell
dvc push/pull --remote daint-local <stages>
```
In this manner, long download times of shared dependencies can be avoided. Using the same technique, it is also possible to spread out pulling/pushing independent stages over multiple nodes or even to pipeline `dvc commit` and `dvc push` over two nodes. If storage capacity is a concern, one may also instead of creating a local remote consider replacing in separate clones of the Git/DVC repo all top folders under `$(dvc root)` *except* `.dvc` by symbolic links (`ln -s <target> <link>`) to the main clone.

# Setting up a new DVC repo with Castor in a subdirectory

## Create a Python environment for DVC & Openstack Swift

For the initial setup (tested on Ubuntu), first install the dependencies
```shell
# https://docs.openstack.org/newton/user-guide/common/cli-install-openstack-command-line-clients.html
sudo apt install python3-dev python3-pip
```

and change to the desired subdirectory that you would like to manage with DVC. We will assume that this is `data/v0` (the second level for versioning) for the rest of this walkthrough, hence run

```shell
mkdir -p data/v0 && cd data/v0
```

Create a Python3 virtual environment with OpenStack Swift and DVC installed as in 
```shell
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip

# Install Openstack client
pip install python-openstackclient lxml oauthlib python-swiftclient python-heatclient

# Install DVC
pip install dvc[s3] jinja2
```

Depending on your particular `dvc --version`, you may want to apply some [patches](data/dvc_tools/patches/README.md) to make it work with the Openstack S3 interface (version 1) or, and this is recommented in particular, environment variables in DVC stages (version 2). The latter can be applied using

```shell
patch venv/lib/python*/site-packages/dvc/parsing/interpolate.py "$(git rev-parse --show-toplevel)"/data/dvc_tools/patches/dvc_2_env_variables_parsing_interpolate.patch
```

## Generate access credentials for the OpenStack Swift object storage

Every new user of the DVC repo on Castor first needs to create S3 access credentials. First, set up an openstack CLI environment for Castor with
```shell
source openstack/cli/castor.env
```
You will need to log in and specify your project. Then you can create EC2 credentials using
```shell
openstack ec2 credentials create --project <project-name/ID>
openstack ec2 credentials list
```
and put them in `~/.aws/credentials` as described in the [boto3 docs](https://boto3.amazonaws.com/v1/documentation/api/latest/guide/credentials.html#guide-credentials), i.e. `Access` and `Secret` into
```shell
[<aws-profile-name>]
aws_access_key_id=<openstack-access>
aws_secret_access_key=<openstack-secret>
```
Here, `<aws-profile-name>` is a placeholder - it is suggested that you use the name of your project in `castor.cscs.ch`. If this is not possible, you can also put the credentials under a different block (using e.g. `default` as the AWS profile name).

## Setting up a subdirectory in which you track your experiments

The following steps only have to be performed once per project. To set up a subdirectory in `data/v0` (the second level for versioning) for tracking workflow results with DVC, in that directory run 

```shell
dvc init --subdir
dvc config core.analytics false
```
You will now have an empty directory, whose contents are tracked by DVC, but not yet synchronized with any remote storage. The second step disables DVC analytics and is optional. Now, create an object storage container on `castor.cscs.ch` under the appropriate project to mirror the contents of the `data/v0` directory (e.g. use `<app-name-data-v0>`).

Then, configure your remote with 
```shell
dvc remote add --default --verbose castor s3://<name-of-your-castor-bucket>
dvc remote modify --verbose castor endpointurl https://object.cscs.ch
dvc remote modify --verbose castor profile <aws-profile-name>
```
according to [this](https://user.cscs.ch/storage/object_storage/) and  [this](https://user.cscs.ch/storage/object_storage/usage_examples/boto/). The third command is necessary if you've put the newly created AWS credentials under a non-`default` AWS profile above (suggestion is to use that on castor.cscs.ch).

The `.dvc/config` may look like this

```shell
[core]
    analytics = false
    remote = castor
['remote "castor"']
    url = s3://<name-of-your-castor-bucket>
    endpointurl = https://object.cscs.ch
    profile = <aws-profile-name>
```

Further configuration options can be obtained either from [this discussion](https://github.com/iterative/dvc/issues/1029#issuecomment-414837587) or directly from the source code. 

You can then copy a DVC repo YAML definition of your choice from [data/dvc_tools/dvc_defs/repos](data/dvc_tools/dvc_defs/repos) to `data/v0/dvc_root.yaml`. After updating the `dvc_root` field to `.` (the relative path to `data/v0`) and if using EncFS [initializing an encrypted directory `encrypt`](data/dvc_tools/encfs_scripts/README.md), commit the newly set up DVC environment to Git with

```shell
git add .dvc/config dvc_root.yaml encrypt/.encfs6.xml && git commit -m "Added data/v0 as a new DVC-tracked subdirectory with <name-of-your-castor-bucket> S3 bucket on Castor as a remote"
```

# Restoring the DVC repo on a different machine

When you `git push` the above commit, you will be able to `git clone` the repo on another machine, set up the python virtual environment as in

```shell
cd data/v0
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install dvc[s3] jinja2
patch venv/lib/python*/site-packages/dvc/parsing/interpolate.py "$(git rev-parse --show-toplevel)"/data/dvc_tools/patches/dvc_2_env_variables_parsing_interpolate.patch
```
and will have a working DVC setup (e.g. using `dvc pull <target-name>` will pull files from Castor).

If you would like to regenerate the exact same Python environment on all machines, you can use `pip freeze > requirements.txt` on the first one, commit this along with the `.dvc/config` and replace `pip install dvc[s3]` above by running `pip install -r requirements.txt` on all others. An alternative is to use a fixed version of DVC as in `pip install dvc[s3]==X.Y.Z`.


# Further S3 configuration for large files

Depending on your requirements (file sizes, etc.), you may find that you need to configure the S3 transfers appropriately, cf. the "S3 Custom command settings" available in the [AWS_CONFIG_FILE](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html). As an example, the following configuration will increase the maximum transferable file size to 128 GB,

```
[profile <aws-profile-name>]
s3 =
  multipart_threshold = 256MB
  multipart_chunksize = 128MB
```

This configuration can be stored under `$(dvc root)/.aws_config` and needs to be available to dvc as an environment variable, i.e. run

```shell
export AWS_CONFIG_FILE=$(realpath $(dvc root)/.aws_config)
```

from within `data/v0`.

### TODO: Experiment monitoring with MLflow
