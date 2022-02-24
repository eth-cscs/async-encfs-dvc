# Experiment tracking with DVC on Castor object storage at CSCS

## Create a Python environment for DVC & Openstack Swift

For the initial setup (tested on Ubuntu), install 
```shell
sudo apt install python3-dev python3-pip
```
and create a Python3 virtual environment as in 
```shell
./setup.sh
```
A side-remark for DVC version 1 (no longer applies to 2.9.4): The Openstack Swift patch is applied to dvc/tree/s3.py as in https://stackoverflow.com/a/60566758 during the setup, i.e. `config=botocore.client.Config(signature_version='s3')` is added as a parameter to `session.resource()` call in line 80 dvc/tree/s3.py of `dvc[s3]==1.9.1`.

## Generate access credentials for the OpenStack Swift object storage

Every new user of the repo first needs to create S3 access credentials for DVC. First, set up an openstack CLI environment for Castor with
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
Here, `<aws-profile-name>` is a placeholder - it is suggested that you use the name of your project in castor.cscs.ch. If this is not possible, you can also put the credentials under a different block (using e.g. `default` as the AWS profile name).

## Setting up a subdirectory in which you track your experiments

The following steps only have to be performed once per project. To set up a subdirectory in `data` for tracking experiments, run 

```shell
mkdir data && cd data && dvc init --subdir
```
You'll now have an empty directory, whose contents are tracked by DVC, but not yet synchronized with any remote storage. If you prefer it, you can disable DVC analytics with `dvc config core.analytics false`.

Configure your remote with 
```shell
dvc remote add --default --verbose castor s3://<name-of-your-castor-bucket>
dvc remote modify --verbose castor endpointurl https://object.cscs.ch
```
according to [this](https://user.cscs.ch/storage/object_storage/) and  [this](https://user.cscs.ch/storage/object_storage/usage_examples/boto/). The `.dvc/config` may look like this

```shell
[core]
    analytics = false
    remote = castor
['remote "castor"']
    url = s3://hpc-predict-castor-test
    endpointurl = https://object.cscs.ch
```
If you've put the newly created AWS credentials under a non-`default` AWS profile above (suggestion: use that on castor.cscs.ch), then you need to change the profile DVC uses accordingly with,
```
dvc remote modify castor profile <aws-profile-name>
```
Further configuration options can be obtained either from [this discussion](https://github.com/iterative/dvc/issues/1029#issuecomment-414837587) or directly from the source code.

You can now run `pip freeze > requirements.txt` and commit the new DVC remote setup to Git with
```shell
git commit .dvc/config requirements.txt -m "Added <name-of-your-castor-bucket> on Castor as a new DVC remote"
```
When you `git push` this commit, you'll be able to `git clone` it elsewhere, set up the python virtual environment 
```shell
cd data
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```
(or simply `pip install dvc[s3]` as the last command) and will have a working DVC setup. 

## Using DVC stages to track results in scientific workflows

For a tutorial on data versioning in DVC stages, consult the [documentation](https://dvc.org/doc/use-cases/versioning-data-and-model-files/tutorial#automating-capturing) on `dvc run`. Note that to version an application's output with the code that was used to produce it we recommend using Git-SHA-tagged container images in the command you supply to `dvc run`. This automatically catches all code-dependencies and makes DVC stages fully re-executable. This is in contrast to the documentation, i.e. we do not to track code dependencies with the `-d` option in `dvc run`, we reserve this option for input data dependencies of the DVC stage.

Some additional considerations
* Systematically structuring experiments into folders can help to keep an overview. Consider e.g.
  + input/{original,preprocessed}/\<appI\>/\<version\>/...
  + \<app1\>/\<version\>/{training,inference}/... (hostname-timestamp-user-labeled individual runs)
  + ...
  + \<appN\>
  + output/\<target_format\> 
* When building a workflow, you need to manage your application data protocols yourself (i.e. in the code, with its own versioning)
  + DVC doesn't have a concept for application protocols, but only of dependencies between files


### Using environment variables in DVC stages

A note on the use of environment variables in DVC stages. DVC version 2 interprets `${MY_VAR}` expressions in command or data dependencies of DVC stages as DVC parameters, so this syntax cannot be used to access shell environment variables or similar. If you don't need DVC parameters, but want shell environment variables to show up in DVC stage definitions (i.e. `dvc.yaml`), you can modify the [`KEYCRE` variable](https://github.com/iterative/dvc/blob/main/dvc/parsing/interpolate.py#L23) in the string interpolation of DVC's parsing module to e.g.
```python
KEYCRE = re.compile(
    r"""
    (?<!\\)                            # escape \${}
    \${DVC_                            # starts with ${DVC_
    (?P<inner>.*?)                     # match every char inside
    }                                  # end with {
""",
    re.VERBOSE,
)
```
so that only variables starting with `DVC_` (e.g. `${DVC_MY_VAR}`) get expanded with DVC parameters. This change can be done manually in the virtual environment after DVC has been successfully installed.
