# Usage details and implementation insights

This document gives a deep dive into usage- and implementation-related details of `async_encfs_dvc`. When looking for an illustration of the capabilities of the package, it is recommended to first consult the [main documentation](README.md) and, in particular, the notebooks listed therein in the section on [usage](README.md#usage). 

## Background

For information on data versioning with DVC stages, consult the [documentation](https://dvc.org/doc/use-cases/versioning-data-and-model-files/tutorial#automating-capturing) of the `dvc stage add` and `repro` commands. `dvc exp` is currently incompatible with asynchronous SLURM stages (due to the [tight coupling of stage execution and commit](https://github.com/iterative/dvc/blob/dd187df6674688ad82f0e933b589a8953c465e1c/dvc/repo/experiments/executor/base.py#L459-L478)), but it can be used when launching [synchronous SLURM jobs (with blocking)](#synchronous-execution-of-dvc-experiments-with-slurm-using-a-centralized-controller).

It is important to note that we version a application output data with the code that was used to produce it by using Git-SHA-tagged container images. This is in contrast to DVC's documentation, where code dependencies are tracked like data dependencies with the `-d` option in `dvc stage add`.

## General usage

The [`dvc_create_stage`](async_encfs_dvc/dvc_create_stage) utility generates a DVC stage based on an application policy that includes a concise definition of an application's runtime environment and references a DVC repository structure and stage policies, all written in YAML. We use an infrastructure-as-code approach with the YAML usage inspired by similar tools like Ansible. In particular, the application and stage policies can be parameterized in Jinja2 syntax allowing the user a certain flexibility, which is exposed through `dvc_create_stage`'s command line interface.

Typical usage with the example applications for [app_ml](examples/app_ml/dvc_app.yaml) takes the form 
```shell
dvc_create_stage --app-yaml examples/app_ml/dvc_app.yaml --stage inference ... 
```
where the application policy is specified in `--app-yaml` and the stage to run in `--stage`. The latter must correspond to an entry at `app > stages` in the application policy, e.g. for `examples/app_ml/dvc_app.yaml`, `training` and `inference` are valid options as defined in the included [training](async_encfs_dvc/dvc_policies/stages/dvc_ml_training.yaml) and [inference](async_encfs_dvc/dvc_policies/stages/dvc_ml_inference.yaml) policies. Completion suggestions for the remaining parameters of the `dvc_create_stage` command line based on the current repository state can be displayed using `--show-opts`.

To describe the DVC repository structure and stage policies, the application definition [`dvc_app.yaml`](examples/app_ml/dvc_app.yaml) includes corresponding files from [async_encfs_dvc/dvc_policies](async_encfs_dvc/dvc_policies) as described before. For each application stage in `dvc_app.yaml` a `type` is referenced in `dvc_app.yaml` and a corresponding stage definition imported (under `include`) that declares the stage's data dependencies and outputs as well as associated commandline parameters. For `examples/app_ml/dvc_app.yaml` the imported definitions are [dvc_ml_training.yaml](async_encfs_dvc/dvc_policies/stages/dvc_ml_training.yaml) and [dvc_ml_inference.yaml](async_encfs_dvc/dvc_policies/stages/dvc_ml_inference.yaml). In addition, `dvc_app.yaml` also imports a DVC repository policy (under the `dvc_root` field) that specifies the top-level layout of a DVC-managed directory (as compared to the stage policies that specify the layout of stages). In particular, there are examples of both a DVC repo with EncFS-encryption ([dvc_root_encfs.yaml](async_encfs_dvc/dvc_policies/repos/dvc_root_encfs.yaml)) and without encryption ([dvc_root_plain.yaml](async_encfs_dvc/dvc_policies/repos/dvc_root_plain.yaml)). The repository policy is fixed at initialization time using `dvc_init_repo` placed in the folder `.dvc_policies` together with a set of reusable stage policies.

To generate a DVC stage, `dvc_create_stage` in a first step processes the `include`s required by `--stage` (discarding all other entries `app > stages`). Secondly, all YAML anchors are resolved and the Jinja2 template variables substituted and the resulting full stage definition is written to a file that will be moved to the stage's `dvc.yaml` directory. The values for the Jinja2 variables can be set via the commandline (replace `_` by `-` for this purpose and use `--show-opts` for commandline completion suggestions). The Jinja2 template variables are the primary customization point for DVC stages generated with `dvc_create_stage`.

From the resulting full stage definition, `dvc_create_stage` then creates the actual DVC stage using `dvc stage add ...` (this can be performed on its own when the full stage definition is already available). Once the DVC stage is generated, it can be run using the familiar `dvc repro .../dvc.yaml` or `dvc repro --no-commit .../dvc.yaml` with SLURM. When using `EncFS`, make sure the `ENCFS_PW_FILE` and possibly also `ENCFS_INSTALL_DIR` are set in the environment (for details, consult the guide at [async_encfs_dvc/encfs_int/README.md](async_encfs_dvc/encfs_int/README.md)).

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
└── out
    └── <target-format>
        ├── <app1>
...
        └── <appN>
```

The datasets in `in/<datasetX>_<version>/original` are usually `dvc add`-ed (e.g. at the level of the `<version>` folder) if they are not the result of a DVC stage and every change to such a dataset requires a `dvc commit` (as when updating stage outputs).

For an `EncFS`-managed repository (cf. [README.md](async_encfs_dvc/encfs_int/README.md)), stage data will be split into an `EncFS`-encrypted directory `encrypt` and an unencrypted directory `config` for DVC stage files and non-private meta-information. The repo structure below `encrypt` and `config` is identical.

The repo and stage policies in [async_encfs_dvc/dvc_policies](async_encfs_dvc/dvc_policies) represent a starting point when initializing a repository that is to be extended/customized and evolved over time in a project.

## SLURM integration

### Asynchronous execution of DVC stages with SLURM

Using `dvc repro --no-commit` one can run DVC stages asynchronously as SLURM jobs with `sbatch` directly from the command line of a SLURM job submission node. This can be a login node of a supercomputer or a short-lived controller-node allocated with
```shell
$ salloc --job-name dvc_op_<repo-hash> --dependency singleton --nodes 1 ...
```
where `<repo-hash>` is `$(echo -n $(realpath $(dvc root)) | sha1sum | head -c 12)`. In particular, for each DVC stage a job is submitted for the actual application command (named `dvc_<stage-name>_<repo-hash>`), upon its successful completion a `dvc commit` job is executed, and upon stage failure a cleanup job. Optionally, a `dvc push` job (to a remote such as Castor) that runs after the `dvc commit` job can be submitted as well. The command `dvc repro --no-commit` returns when these jobs are successfully submitted to the SLURM queue (hence, the use of `--no-commit` to avoid copying unnecessary files to the DVC cache). That is, the application has not yet executed and any of the data dependencies should not be edited before both the application stage and commit jobs have completed asynchronously.

DVC dependencies are respected by mapping them to SLURM dependencies of the application jobs. A potential conflict for the `$(dvc root)/.dvc/tmp/rwlock` that is acquired by many `dvc` commands (such as `repro`, `commit` and `push`) that fail if they cannot acquire it is in parts avoided by naming all `dvc commit` and `dvc push` SLURM jobs as `dvc_op_<repo-hash>` and only allowing a single of these to be running per DVC repo (implemented in SLURM using the `--dependency singleton` option of `sbatch`). 

When submitting DVC SLURM stages with `dvc repro` (which also acquires this lock), it is the responsibility of the user that no `dvc commit` or `dvc push` jobs on the same DVC repo are running concurrently in the background. As a first measure, it is recommended to have only a single user actively running jobs on a DVC repo. To display the status of `dvc` jobs, one can use the [`dvc_scontrol`](async_encfs_dvc/slurm_int/dvc_scontrol) utility with `show <job-type>` where `<job-type>` can be `stage`, ` commit` or `push`. Furthermore, by default all jobs are submitted in `--hold` state to the SLURM queue, so that the user has time to run more DVC commands and can unblock the jobs when done with DVC using `scontrol release <jobid>` or in bulk [`dvc_scontrol`](async_encfs_dvc/slurm_int/dvc_scontrol) `release <job-type>`. In case another `dvc repro` (or another locking command such as `dvc status`) needs to be run, one can put a repo's `stage`, `commit` and `push` jobs on hold/requeue them with the `hold` command of `dvc_scontrol` (and `release` them again when done). Alternatively and less safely, the `sbatch` jobs can be submitted without the `--hold` option by setting `DVC_SLURM_DVC_OP_NO_HOLD=YES` in the `dvc repro` environment, e.g. when using the above `salloc`-command for a short-lived controller node. 

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

