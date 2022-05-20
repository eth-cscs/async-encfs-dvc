# Tutorial: A DVC demo repo for an ML workflow

In the following, we build a demo pipeline that tracks original (unmodified) input data, preprocesses it and then performs ML training/inference stages. For simplicity, we assume not to use `EncFS`, containers and SLURM, but focus on the stage policies/folder and file hierarchy as well as the structure of `dvc_app.yml`. All of the additional features can be activated later (in `dvc_app.yml`) without difficulty. 

First create a dvc repository using `dvc init --subdir` in a subfolder of `data` as shown in the main [README](../README.md). We assume that our training/test/inference data is comes from the `ml_dataset` and focus on the subset labeled `ex1` (which could be chosen differently for each of the three). Executing the following from the root dir of the repo populates it with this data
```bash
mkdir -p input_data/{original,preprocessed}
mkdir -p input_data/original/ml_dataset/v1/{training,test,inference}/ex1
touch input_data/original/ml_dataset/v1/{training,test,inference}/ex1/in.dat
for d in input_data/original/ml_dataset/v1/{training,test,inference}; do
    cd $d && dvc add ex1 && cd -
done
tree input_data
```

We can now run the preprocessing stages. For the `training` data, we choose a manual step that is run outside of DVC (e.g. in a GUI or elsewhere). Nevertheless, it must respect the data dependencies supplied to DVC. To generate this stage, we run
```bash
../dvc_tools/dvc_create_stage.py --app-yaml ../../app_prep/dvc_app.yaml --stage manual_train --run-label ex1-etl-train --input-etl ex1 --input-etl-file in.dat 
```
This creates a `frozen` stage (configured in [dvc_app.yaml](../app_prep/dvc_app.yaml)) with a no-op command that is never executed upon `dvc repro`. Then we can `cd` to the directory containing `dvc.yaml`, inspect its `deps` and `outs` and (manually) create the output data in `output` using the referenced input deps e.g. in a GUI app or for the sake of this tutorial just copy the `dep` to the `output` dir. When done, we have to commit the new output with
```bash
dvc commit input_data/preprocessed/ml_dataset/v1/training/app_prep/v1/manual/ex1-etl-train/dvc.yaml
```

Let's assume that for the other data, we have automated the preprocessing, so that we can create and run these stages with
```bash
# test-data
../dvc_tools/dvc_create_stage.py --app-yaml ../../app_prep/dvc_app.yaml --stage auto_test   --run-label ex1-etl-test   --input-etl ex1 --input-etl-file in.dat  # adapt etl_input_data anchor to test
dvc repro input_data/preprocessed/ml_dataset/v1/test/app_prep/v1/auto/ex1-etl-test/dvc.yaml
# inference-data
../dvc_tools/dvc_create_stage.py --app-yaml ../../app_prep/dvc_app.yaml --stage auto_inf   --run-label ex1-etl-inf   --input-etl ex1 --input-etl-file in.dat
dvc repro input_data/preprocessed/ml_dataset/v1/inference/app_prep/v1/auto/ex1-etl-inf/dvc.yaml
```

As a next step, we set up a basic structure for an ML app that uses the preprocessed data. For this we run

```bash
mkdir -p app_ml/v2/{training,inference,config}
# create a hyperparameter configuration
mkdir -p app_ml/v2/config/ex1-config
touch app_ml/v2/config/ex1-config/hp.yaml
cd app_ml/v2/config && dvc add ex1-config && cd -
tree app_ml
```
where the file `hp.yaml` contains hyperparameters and model architecture specifications that are fixed during training.

This allows us to create ML training and inference stages (use completion suggestions with `--show-opts`) with
```bash
../dvc_tools/dvc_create_stage.py --app-yaml ../../app_ml/dvc_app.yaml --stage training  --run-label ex1-train --input-config ex1-config --input-config-file hp.yaml --input-training ex1-etl-train --input-test ex1-etl-test

../dvc_tools/dvc_create_stage.py --app-yaml ../../app_ml/dvc_app.yaml --stage inference --run-label ex1-inf   --input-config ex1-config --input-config-file hp.yaml --input-training ex1-train     --input-inference ex1-etl-inf
```
that can be inspected
```bash
dvc dag app_ml/v2/inference/ex1-inf/dvc.yaml 
```
and eventually run with
```bash
dvc repro app_ml/v2/inference/ex1-inf/dvc.yaml 
```
