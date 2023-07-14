# Data version control in privacy-preserving HPC workflows using DVC, EncFS, SLURM and Openstack Swift on castor.cscs.ch

This project applies infrastructure-as-code principles to [DVC](https://dvc.org) and integrates it with [EncFS](https://github.com/vgough/encfs) and [SLURM](https://slurm.schedmd.com) to track results of scientific HPC workflows in a privacy-preserving manner, exchanging them via the OpenStack Swift object storage at `castor.cscs.ch`.

The **key features** extending DVC include
* SLURM integration for HPC clusters: DVC stages and their dependencies can be executed asynchronously using SLURM (`dvc repro` submits a SLURM job, `dvc commit` is run upon job completion)
* privacy-preservation: DVC stages can utilize a transparently encrypted filesystem with [EncFS](https://github.com/vgough/encfs) ensuring no unencrypted data is persisted to storage or exchanged through DVC (see [further details](data/dvc_tools/encfs_scripts/README.md))
* container engine support: DVC stages can be run with Docker and [Sarus](https://github.com/eth-cscs/sarus). Code dependencies are tracked via Git-SHA-tagged container images, making stages fully re-executable
* infrastructure-as-code practice: DVC repository structure and stage policies can be encoded into reusable YAML definitions, enabling applications to generate DVC stages that conform to these requirements

These capabilities extend, rather than modify, DVC and can largely be used independently. They are exemplified on three demo applications, [app_ml](app_ml) for a machine learning application, [app_sim](app_sim) for a simulation and [app_prep](app_prep) for a preprocessing step (manual and automated). Each of them is accompanied by a corresponding stage policy that can be customized inside a DVC repository to reflect evolving requirements. 

A real-world scenario may also include custom application protocols. They can be defined in an additional package (e.g. `app_protocol`) that is imported by the participating applications. It is important to note that DVC does not have a concept for application protocols, but only tracks dependencies between files.  

Thus, the project aims to provide a flexible platform that can be customized according to specific project needs. For an overview of the tool's usage and performance results on Piz Daint and Castor object storage, refer to the [usage](#usage) section and [performance report](#performance-on-piz-daint-and-castor) respectively.

For a step-by-step guide on setting up a DVC repository to track workflow results using Castor as a remote, please refer to [Setting up a new DVC repo with Castor](#setting-up-a-new-dvc-repo-with-castor-in-a-subdirectory). To explore the project's functionality, consider the [Machine Learning tutorial](examples/ml_tutorial.ipynb) that describes how to set up a repository for an ML workflow and the `iterative_sim` [benchmark](benchmarks) for an iterative simulation workflow.

## Background

For more information on data versioning with DVC stages, consult the [documentation](https://dvc.org/doc/use-cases/versioning-data-and-model-files/tutorial#automating-capturing) of the `dvc stage add` and `repro` commands (`dvc exp` is currently incompatible with asynchronous SLURM stages due to the [tight coupling of stage execution and commit](https://github.com/iterative/dvc/blob/dd187df6674688ad82f0e933b589a8953c465e1c/dvc/repo/experiments/executor/base.py#L459-L478), but it can be used when launching [synchronous SLURM jobs from a centralized controller](#synchronous-execution-of-dvc-experiments-with-slurm-using-a-centralized-controller)).

It is important to note that we version an application's output with the code that was used to produce it by using Git-SHA-tagged container images in the command supplied to `dvc stage add`. This is in contrast to DVC's documentation, which tracks code dependencies as data with the `-d` option in `dvc stage add` (which we reserve for input data dependencies).

# Installation

In your Python environment, run
```
pip install git+https://github.com/eth-cscs/async-encfs-dvc.git
```
This will install all dependencies except for EncFS. If you require encryption, follow the separate [installation instructions](async_encfs_dvc/encfs_scripts/README.md) for EncFS.

# Usage

## Example

A demonstration of the DVC stage generation for an ML/simulation pipeline is available under the [ML repository tutorial](examples/ml_tutorial.ipynb).


## Details on general usage

The [`dvc_create_stage`](data/dvc_tools/dvc_create_stage) utility generates a DVC stage based on an application policy that includes a concise definition of an application's runtime environment and references a DVC repository structure and stage policies, all written in YAML. We use an infrastructure-as-code approach with the YAML usage inspired by similar tools like Ansible. In particular, the application and stage policies can be parameterized in Jinja2 syntax allowing the user a certain flexibility, which is exposed through `dvc_create_stage`'s command line interface.

Typical usage with the example applications for [app_ml](app_ml/dvc_app.yaml) takes the form 
```shell
dvc_create_stage --app-yaml app_ml/dvc_app.yaml --stage inference ... 
```
where the application policy is specified in `--app-yaml` and the stage to run in `--stage`. The latter must correspond to an entry at `app > stages` in the application policy, e.g. for `examples/app_ml/dvc_app.yaml`, `training` and `inference` are valid options as defined in the included [training](async_encfs_dvc/dvc_policies/stages/dvc_ml_training.yaml) and [inference](async_encfs_dvc/dvc_policies/stages/dvc_ml_inference.yaml) policies. Completion suggestions for the remaining parameters of the `dvc_create_stage` command line based on the current repository state can be displayed using `--show-opts`.

To describe the DVC repository structure and stage policies, the application definition [`dvc_app.yaml`](app_ml/dvc_app.yaml) includes corresponding files from [async_encfs_dvc/dvc_policies](async_encfs_dvc/dvc_policies) as described before. For each application stage in `dvc_app.yaml` a `type` is referenced in `dvc_app.yaml` and a corresponding stage definition imported (under `include`) that declares the stage's data dependencies and outputs as well as associated commandline parameters. For `app_ml/dvc_app.yaml` the imported definitions are [dvc_ml_training.yaml](async_encfs_dvc/dvc_policies/stages/dvc_ml_training.yaml) and [dvc_ml_inference.yaml](async_encfs_dvc/dvc_policies/stages/dvc_ml_inference.yaml). In addition, `dvc_app.yaml` also imports a DVC repository policy (under the `dvc_root` field) that specifies the top-level layout of a DVC-managed directory (as compared to the stage policies that specify the layout of stages). In particular, there are examples of both a DVC repo with EncFS-encryption ([dvc_root_encfs.yaml](async_encfs_dvc/dvc_policies/repos/dvc_root_encfs.yaml)) and without encryption ([dvc_root_plain.yaml](async_encfs_dvc/dvc_policies/repos/dvc_root_plain.yaml)). The repository policy is fixed at initialization time using `dvc_init_repo` placed in the folder `.dvc_policies` together with a set of reusable stage policies.

To generate a DVC stage, `dvc_create_stage` in a first step processes the `include`s required by `--stage` (discarding all other entries `app > stages`). Secondly, all YAML anchors are resolved and the Jinja2 template variables substituted and the resulting full stage definition is written to a file that will be moved to the stage's `dvc.yaml` directory. The values for the Jinja2 variables can be set via the commandline (replace `_` by `-` for this purpose and use `--show-opts` for commandline completion suggestions). The Jinja2 template variables are the primary customization point for DVC stages generated with `dvc_create_stage`.

From the resulting full stage definition, `dvc_create_stage` then creates the actual DVC stage using `dvc stage add ...` (this can be performed on its own when the full stage definition is already available). Once the DVC stage is generated, it can be run using the familiar `dvc repro .../dvc.yaml` or `dvc repro --no-commit .../dvc.yaml` with SLURM. When using `EncFS`, make sure the `ENCFS_PW_FILE` and possibly also `ENCFS_INSTALL_DIR` are set in the environment (for details, consult the guide at [async_encfs_dvc/encfs_scripts/README.md](async_encfs_dvc/encfs_scripts/README.md)).

The generated DVC stage will then automatically respect the prescribed stage policy and repo structure. In the case of the examples it takes the following layout (without encryption)

```
$ tree
.
├── in
│   ├── <dataset1>_<version>
│   │    ├── original
│   │    └── <etl-app>_<version>
│   │         └── <run-label>
...
│   └── <datasetM>
...
├── <app1>
│    ├── <datasetX>_<version>
│    │    ├── <app1-version>
│    │    │    ├── <stage_a>
│    │    │    │    └── <run-label>
│    │    │    └── <stage_b>
│    │    │         └── <run-label>
...
│    │    └── <app1-version>
...
│    └── <datasetY>_<version>
...
├── <appN>
│   └── <datasetY>_<version>
...
└── output_data
    └── <target_format>
        ├── <app1>
...
        └── <appN>
```

The datasets in `input_data/original` are usually `dvc add`-ed (e.g. at the level of the `<version>` folder) if they are not the result of a DVC stage and every change to such a dataset requires a `dvc commit` (as when updating stage outputs).

For an `EncFS`-managed repository (cf. [README.md](async_encfs_dvc/encfs_scripts/README.md)), stage data will be split into an `EncFS`-encrypted directory `encrypt` and an unencrypted directory `config` for DVC stage files and non-private meta-information. The repo structure below `encrypt` and `config` is identical.

The repo and stage policies in [async_encfs_dvc/dvc_policies](async_encfs_dvc/dvc_policies) represent a starting point when initializing a repository that is to be extended/customized and evolved over time in a project.

## Details on usage with SLURM

### Asynchronous execution of DVC stages with SLURM

Using `dvc repro --no-commit` one can run DVC stages asynchronously as SLURM jobs with `sbatch` directly from the command line of a SLURM job submission node. This can be a login node of a supercomputer or a short-lived controller-node allocated with
```shell
$ salloc --job-name dvc_op_<repo-hash> --dependency singleton --nodes 1 ...
```
where `<repo-hash>` is `$(echo -n $(realpath $(dvc root)) | sha1sum | head -c 12)`. In particular, for each DVC stage a job is submitted for the actual application command (named `dvc_<stage-name>_<repo-hash>`), upon its successful completion a `dvc commit` job is executed, and upon stage failure a cleanup job. Optionally, a `dvc push` job (to a remote such as Castor) that runs after the `dvc commit` job can be submitted as well. The command `dvc repro --no-commit` returns when these jobs are successfully submitted to the SLURM queue (hence, the use of `--no-commit` to avoid copying unnecessary files to the DVC cache). That is, the application has not yet executed and any of the data dependencies should not be edited before both the application stage and commit jobs have completed asynchronously.

DVC dependencies are respected by mapping them to SLURM dependencies of the application jobs. A potential conflict for the `$(dvc root)/.dvc/tmp/rwlock` that is acquired by many `dvc` commands (such as `repro`, `commit` and `push`) that fail if they cannot acquire it is in parts avoided by naming all `dvc commit` and `dvc push` SLURM jobs as `dvc_op_<repo-hash>` and only allowing a single of these to be running per DVC repo (implemented in SLURM using the `--dependency singleton` option of `sbatch`). 

When submitting DVC SLURM stages with `dvc repro` (which also acquires this lock), it is the responsibility of the user that no `dvc commit` or `dvc push` jobs on the same DVC repo are running concurrently in the background. As a first measure, it is recommended to have only a single user actively running jobs on a DVC repo. To display the status of `dvc` jobs, one can use the [`slurm_jobs.sh`](data/dvc_tools/slurm_scripts/slurm_jobs.sh) utility with `show <job-type>` where `<job-type>` can be `stage`, ` commit` or `push`. Furthermore, by default all jobs are submitted in `--hold` state to the SLURM queue, so that the user has time to run more DVC commands and can unblock the jobs when done with DVC using `scontrol release <jobid>` or in bulk [`slurm_jobs.sh`](data/dvc_tools/slurm_scripts/slurm_jobs.sh) `release <job-type>`. In case another `dvc repro` (or another locking command such as `dvc status`) needs to be run, one can put a repo's `stage`, `commit` and `push` jobs on hold/requeue them with the `hold` command of `slurm_jobs.sh` (and `release` them again when done). Alternatively and less safely, the `sbatch` jobs can be submitted without the `--hold` option by setting `DVC_SLURM_DVC_OP_NO_HOLD=YES` in the `dvc repro` environment, e.g. when using the above `salloc`-command for a short-lived controller node. 

In the `dvc repro` environment, generating the `dvc push` job that runs upon completion of `dvc commit` can be enabled by setting `DVC_SLURM_PUSH_ON_COMMIT=YES`. Otherwise a script is generated in the `dvc.yaml` folder that allows to submit a corresponding SLURM `dvc push` job later respecting DVC dependencies.


### Known pitfalls and limitations

The provided support for asynchronous SLURM stages in DVC is a proof-of-concept of how to run asynchronous stages without modifying DVC directly. To avoid unexpected behavior, it is recommended to follow these points
* Only have a single user actively running jobs on a DVC repo. 
  * This avoids unintended competition for the DVC lock and permission issues with SLURM job control commands that do not work across different users.
* Do not run `dvc repro` concurrently with another locking `dvc` command (such as `dvc commit`, `dvc push` or `dvc status`) in the same DVC repo, instead run them sequentially (one after the other).
* Do not rely on the output of `dvc status` while executing asynchronous SLURM stages. 
  * DVC has no immediate concept for asynchronous stages: When `dvc repro` is run on a SLURM stage, it returns upon submission of stage, commit/cleanup (and possibly push) SLURM jobs believing that the stage has been completed and correspondingly updating the `dvc.lock` file (altered behavior needs to be implemented directly in DVC), when actually only the stage job will produce the results and the commit job update `dvc.lock` correspondingly  (or the cleanup job remove it in case of stage failure). The actual status of asynchronous SLURM stages is tracked in `<stage-name>.<status>` files in the `dvc.yaml` folder (and could be a feature in `dvc.lock` to track asynchronously completed stages).
* Do not modify input dependencies or outputs of DVC SLURM stages before the stage, `dvc commit` and optionally `dvc push` jobs have completed.
  * In particular do not launch another DVC stage (both SLURM and non-SLURM) that modifies these as there is no lock in place that guarantees mutually exclusive (concurrent) access to dependency and output data sets for `dvc repro` (needs to be implemented in DVC).
* Do not launch a pipeline with a mix of SLURM stages and non-SLURM stages in a `dvc repro` call on a SLURM cluster (only run exclusively either or)
  * SLURM stages are executed asynchronously (as SLURM jobs, after `dvc repro` returned, only the job submission happens synchronously), whereas non-SLURM jobs require their inputs to be available when `dvc repro` executes. 
  * To support a mixture in `dvc repro` would require that at every non-SLURM stage a check is made that all dependencies are also of non-SLURM type or (optionally) the execution waits until the SLURM dependency completes. Although this could be implemented in another script analogous to `slurm_enqueue.sh`, a clean solution requires changes to DVC.
* Use a dedicated allocation with `salloc` to run `dvc repro` (or similar commands) on a DAG that has already been partially executed but not committed 
  * DVC will try to synchronously commit any un-/partially committed stages which can lead to high resource consumption on the localhost. Use the above `salloc` command to re-run any failed/incompletely run `dvc commit` jobs on stages, where the application has successfully completed.
* When running `dvc repro` on a pipeline of SLURM stages that depends on another SLURM pipeline that was already submitted before, make sure that the dependency on the formerly scheduled pipeline has either not yet started the application stage (e.g. in held state) or finished `dvc commit`.
  * If the stage has started and the data has not yet been committed, the `dvc repro` on the dependent pipeline will detect the change of output data in the dependency and trigger a file hash computation (needs to be changed in DVC). 

To support asynchronous stages in DVC would require
* a mechanism for setting up and tracking asynchronous stages (e.g. by adding an option to `dvc stage add`) that is updated on execution (to `pending`, with jobid, like in `slurm_enqueue.sh`, further updated by the DVC command to `running`/`completed`/`failed` like in the sbatch scripts) and taken into account during DAG scheduling (e.g. blocking on demand by the user/aborting when a synchronous stage depends on an asynchronous one that is not yet completed, informing the external scheduler (or DVC command if scheduler-agnostic) about stage dependencies) as well as by `dvc status`.
* a method to update asynchronous stage status (e.g. by extending `dvc status`) from the running stage as well as a method to clean up stale statuses/runs interactively (e.g. by extending `dvc gc`).
* guaranteeing mutually exclusive, concurrent access to data dependencies/outputs from both SLURM jobs and a controlling terminal to make sure they are not overwritten (cf. `dvc exp --temp`).
* to make this work for `dvc exp`, stage execution needs to be decoupled from completion handling (commit), which is currently [not the case](https://github.com/iterative/dvc/blob/dd187df6674688ad82f0e933b589a8953c465e1c/dvc/repo/experiments/executor/base.py#L459-L478).
* enabling concurrent execution of `status`/`commit`/`push`/`pull` with short locking sections on unrelated data sets would allow to utilize large clusters efficiently

### Synchronous execution of DVC experiments with SLURM using a centralized controller

As an alternative to the above asynchronous execution of DVC stages, it is possible to execute them synchronously from a centralized controller node if they use [`sbatch --wait`](https://github.com/iterative/dvc/issues/1057#issuecomment-901367180) in the DVC command so that `sbatch` only returns upon completion (or failure) of the SLURM job. This can be useful to e.g. run DVC experiments managed with `dvc exp` queues. The [procedure](https://dvc.org/doc/user-guide/experiment-management) includes first defining experiments (`dvc_create_stage` could be extended to support this) and filling up the queue using `dvc exp run --queue <stage>`, where `<stage>` must use `sbatch --wait ...` if it includes a SLURM job. Then a SLURM job for the centralized controller can be run, e.g. with

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
or a corresponding `salloc` command (same parameters as for `sbatch` above) can be used to run `dvc` commands manually on the allocated node. To maintain long-running sessions for both the `salloc` environment (to keep the SLURM job) and on the allocated node (to run `dvc` commands) [`tmux`](https://github.com/tmux/tmux/wiki) may be useful. From the controller node, DVC will then orchestrate the execution of all experiments.

The upside of this approach is that the full DVC API can be used and SLURM stages can be mixed with non-SLURM stages (executing on the controller node). The downsides are having no possibility to interact with DVC while the controller job (i.e. all the experiments/application stages) is running (unless `dvc exp run --temp` is used, also cf. [new features](https://github.com/iterative/dvc/issues/7592) being developed), less parallelism in stage execution and potentially less efficient scheduling in SLURM due to submitting jobs only upon completion of their dependencies (i.e. DVC takes over dependency handling for SLURM). Also, the controller node needs to outlive all of the scheduling, execution and commit time of an experiment (stage), thus, may spend a lot of time idle (waiting for experiments to be scheduled and run to obtain stage results) and reach the maximum job time limit on some systems (24 h on Piz Daint) before its scheduled experiments finish. For these reasons, the asynchronous DVC stages are currently preferred for large-scale workloads on SLURM clusters. 

# Performance on Piz Daint and Castor

We use the `iterative_sim` benchmark [without](benchmarks/iterative_sim_plain_benchmark.sh) and [with](benchmarks/iterative_sim_encfs_benchmark.sh) `EncFS`. The `iterative_sim` benchmark consists of a set of sequentially dependent DVC stages (a pipeline), where for every DVC stage `app_sim` is run with `Sarus` on 8 GPU nodes, 16 ranks with each rank writing its payload sampled from /dev/urandom with `dd` to the filesystem using a single thread. The aggregate output payload per DVC stage is increased in powers of 2, from 16 GB to 1.024 TB in our runs (using decimal units, i.e. 1 GB = 10^9 B). The subsequent `dvc commit` and `dvc push` commands are run on a single multi-core node. The software configuration used is available at [iterative_sim.config.md](benchmarks/results/iterative_sim.config.md) and detailed logs can be found in the benchmarks branch.

We use three different configurations for 
* **large files**: 1 file per rank, i.e. starting with 1 GB
* **medium-sized files**: 10^3 files per rank, i.e. starting with 1 MB
* **small files**: 10^4 files per rank, i.e. starting with 100 KB
and vary the total per-rank payload from 1 GB to 64 GB in powers of 2 (as stated above). On the `scratch` filesystem on Piz Daint, creating the 7 stages for the DVC pipeline of a single configuration takes around 18 s (irrespective of whether `EncFS` is used).

When run without encryption/`EncFS`, we obtain the following results on Piz Daint for **large files**

| individual file size | per-rank payload | aggregate payload | stage time (SLURM step) | dvc commit time (SLURM step) | dvc push time to Castor (SLURM step) |
| --------------------:| ----------------:| -----------------:| -----------------------:| ----------------------------:| ------------------------------------:|
|  1 GB                |  1 GB            |    16 GB          |   0m 27.052s            |   0m 46.797s                 |    2m 33.804s                        |
|  2 GB                |  2 GB            |    32 GB          |   0m 31.342s            |   1m 19.278s                 |    4m  2.548s                        |
|  4 GB                |  4 GB            |    64 GB          |   1m 22.411s            |   2m 41.182s                 |    7m 43.655s                        |
|  8 GB                |  8 GB            |   128 GB          |   2m  0.840s            |   5m 30.745s                 |   14m 25.279s                        |
| 16 GB                | 16 GB            |   256 GB          |   3m 59.262s            |  11m 14.833s                 |   26m 37.984s                        |
| 32 GB                | 32 GB            |   512 GB          |   7m 42.820s            |  26m 35.141s                 |   55m 34.079s                        |
| 64 GB                | 64 GB            | 1.024 TB          |  15m 35.199s            |  41m  4.529s                 |  110m 26.116s                        |

with **medium-sized files**

| individual file size | per-rank payload | aggregate payload | stage time (SLURM step) | dvc commit time (SLURM step) | dvc push time to Castor (SLURM step) |
| --------------------:| ----------------:| -----------------:| -----------------------:| ----------------------------:| ------------------------------------:|
|  1 MB                |  1 GB            |    16 GB          |   0m 23.444s            |  17m 36.499s                 |    8m  3.508s                        |
|  2 MB                |  2 GB            |    32 GB          |   0m 33.024s            |  19m 52.038s                 |    9m  2.840s                        |
|  4 MB                |  4 GB            |    64 GB          |   1m  1.768s            |  22m 33.451s                 |   13m 32.501s                        |
|  8 MB                |  8 GB            |   128 GB          |   2m  7.507s            |  36m 13.483s                 |   20m 17.103s                        |
| 16 MB                | 16 GB            |   256 GB          |   4m 15.086s            |  39m 57.099s                 |   35m 32.338s                        |
| 32 MB                | 32 GB            |   512 GB          |   7m 43.991s            |  53m 24.634s                 |   65m 55.366s                        |
| 64 MB                | 64 GB            | 1.024 TB          |  15m 40.195s            |  76m  0.389s                 |  123m 25.036s                        |

and with **small files**

| individual file size | per-rank payload | aggregate payload | stage time (SLURM step) | dvc commit time (SLURM step) | dvc push time to Castor (SLURM step) |
| --------------------:| ----------------:| -----------------:| -----------------------:| ----------------------------:| ------------------------------------:|
|   100 KB             |  1 GB            |    16 GB          |   0m 52.073s            |  202m 25.826s                |   50m 17.943s                        |
|   200 KB             |  2 GB            |    32 GB          |   0m 50.400s            |  199m  3.391s                |   55m 47.384s                        |
|   400 KB             |  4 GB            |    64 GB          |   1m 19.986s            |  209m 17.751s                |   59m 49.833s                        |
|   800 KB             |  8 GB            |   128 GB          |   2m 43.147s            |  234m 42.978s                |   68m 18.372s                        |
| 1.600 MB             | 16 GB            |   256 GB          |   4m 27.615s            |  237m 40.735s                |   82m 38.656s                        |
| 3.200 MB             | 32 GB            |   512 GB          |   8m  5.145s            |  272m 10.639s                |  110m 47.234s                        |
| 6.400 MB             | 64 GB            | 1.024 TB          |  15m 55.370s            |  407m 14.425s                |  167m 18.985s                        |

We obtain the following performance numbers for the application stage in the same configurations with encryption/`EncFS`

| per-rank payload | aggregate payload | stage time (large files) | stage time (medium files) | stage time (small files) |
| ----------------:| -----------------:| ------------------------:| -------------------------:| ------------------------:|
|  1 GB            |    16 GB          |   0m 39.529s             |   0m 55.533s              |   1m 57.455s             |
|  2 GB            |    32 GB          |   1m 17.725s             |   1m 15.242s              |   2m 35.338s             |
|  4 GB            |    64 GB          |   2m 28.160s             |   2m 49.697s              |   3m 27.868s             |
|  8 GB            |   128 GB          |   4m 57.152s             |   4m 59.661s              |   5m 44.948s             |
| 16 GB            |   256 GB          |   9m 38.297s             |   9m 46.761s              |  10m  5.082s             |
| 32 GB            |   512 GB          |  18m 47.857s             |  19m 52.775s              |  18m 47.612s             |
| 64 GB            | 1.024 TB          |  37m 27.673s             |  38m 53.677s              |  44m 10.290s             |

These results can be summarized in the following bandwith plot as a function of individual file size.

![iterative_sim benchmark results on Piz Daint/Castor](./benchmarks/results/iterative_sim_results.svg)

When sampling from `/dev/zero` instead of `/dev/urandom`, the write-throughput of the application stage is about 4-5x higher without encryption than with `EncFS` for large files.

Note that only one `dvc commit` or `dvc push` SLURM job can run per DVC repo at any time, while stages can run be concurrently (as long as they are not DVC dependencies of one another). If `dvc commit` or `dvc push` are throughput-limiting steps, the most effective measure is to avoid small file sizes (>= 10 MB is ideal). Besides that, one can increase the performance by running disjoint pipelines in separate clones of the Git/DVC repo. To avoid redundant transfers of large files over a slow network connection, it can be useful to synchronize over the local filesystem by adding a [local remote](https://dvc.org/doc/command-reference/remote#example-add-a-default-local-remote), e.g. with 
```shell
dvc remote add daint-local $SCRATCH/path/to/remote
```
and then 
```shell
dvc push/pull --remote daint-local <stages>
```
In this manner, the download overhead of shared dependencies can be avoided (file hashes are recomputed, however). Furthermore, to avoid long file hash recalculations (in `dvc commit`) upon small, localized changes in a very large file, try to store it as multiple separate files rather than a single very large one if it needs to be changed regularly. When e.g. using HDF5 as an application protocol, consider using external links to split the HDF5 into multiple files each containing a dataset (cf. [this discussion](https://github.com/iterative/dvc/discussions/6776)).

If these techniques do not alleviate the issue with throughput, a draft of running `dvc commit/push` operations `out-of-repo` instead `in-repo` is available (can be activated by exporting `DVC_SLURM_DVC_OP_OUT_OF_REPO=YES`). The intention is to run the computationally expensive part in e.g. `dvc commit` in a separate, temporary DVC repo with all top folders under `$(dvc root)` except `.dvc` as symbolic links to the original repo and then have a short-running process that synchronizes with the main repo. The jobs running on DVC repos outside the main one are then parallelizable. Currently, there is no speedup for `dvc commit`, though, as file hashes are recomputed on every `dvc pull` (i.e. the `cache.db`'s entries are not synchronized by a local `dvc pull`).

# Setting up a new DVC repository with Castor

## Step 1: Create a Python environment with async_encfs_dvc

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
pip install git+https://github.com/eth-cscs/async-encfs-dvc.git
```

This will install the package and all its dependencies including DVC and Openstack Swift.

## Step 2: Generate access credentials for the OpenStack Swift object storage

Every new user of the DVC repo on Castor first needs to create S3 access credentials. First, set up an openstack CLI environment for Castor with
```shell
source "$(python -c 'import async_encfs_dvc; print(async_encfs_dvc.__path__[0])')/openstack/cli/castor-cli-otp.env"
```
If you are not using multifactor-authentication yet, you need to replace `castor-cli-otp.env` by `castor.env` in the above command.

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

## Step 3: Initializing the DVC directory to track your data

The following steps only have to be performed once per project. To set up a subdirectory in `data/v0` (the second level for versioning) for tracking workflow results with DVC, in that directory run 

```shell
dvc_init_repo . <repo-policy>
```
You will now have an empty directory, whose contents are tracked by DVC, but not yet synchronized with any remote storage. In addition, it is pre-configured for the `<repo-policy>`, which can take the values of `plain` for an unencrypted or `encfs` for an EncFS-managed repository. This is stored in `.dvc_policies/repo/dvc_root.yaml`. Furthermore, a set of default stage policies are available under `.dvc_policies/stages` that can be continuously evolved and extended by new policies.

Now, you can create an object storage container on `castor.cscs.ch` under the appropriate project to mirror the contents of the `data/v0` directory (e.g. use `<app-name-data-v0>`).

Then, configure your remote with 
```shell
dvc remote add --default --verbose castor s3://<name-of-your-castor-bucket>
dvc remote modify --verbose castor endpointurl https://object.cscs.ch
dvc remote modify --verbose castor profile <aws-profile-name>
```
according to the CSCS user documentation on [object storage](https://user.cscs.ch/storage/object_storage/) and the [boto client](https://user.cscs.ch/storage/object_storage/usage_examples/boto/). The third command is necessary if you've put the newly created AWS credentials under a non-`default` AWS profile above (suggestion is to use the profile name on castor.cscs.ch).

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

Further configuration options can be obtained either from [this discussion](https://github.com/iterative/dvc/issues/1029#issuecomment-414837587) or directly from DVC's source code. 

You can now copy a DVC repo YAML definition of your choice from [async_encfs_dvc/dvc_policies/repos](async_encfs_dvc/dvc_policies/repos) to `data/v0/dvc_root.yaml`. After updating the `dvc_root` field to `.` (the relative path to `data/v0`) and if using EncFS [initializing an encrypted directory](data/dvc_tools/encfs_scripts/README.md) `encrypt`, commit the newly set up DVC environment to Git with

```shell
git add .dvc/config dvc_root.yaml encrypt/.encfs6.xml && git commit -m "Added data/v0 as a new DVC-tracked subdirectory with <name-of-your-castor-bucket> S3 bucket on Castor as a remote"
```

## Step 4: Restoring the DVC repo on a different machine

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

# Details on S3-object storage management

## Configuration for large files

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


## Deleting object storage containers on Castor

When the data stored on Castor is no longer required, you can delete the associated object storage containers from within the castor environment
```shell
source data/dvc_tools/openstack/cli/castor-cli-otp.env
```
by using the OpenStack swift client,
```shell
swift post <name-of-your-castor-bucket>+segments -H 'X-History-Location:'
swift delete <name-of-your-castor-bucket>
swift delete <name-of-your-castor-bucket>_versions
swift delete <name-of-your-castor-bucket>+segments
swift delete <name-of-your-castor-bucket>+segments_versions
```