### Experiment tracking with DVC on Castor object storage at CSCS

For the initial setup (tested on Ubuntu), install 
```shell
sudo apt install python3-dev python3-pip
```
and create a Python3 virtual environment as in 
```
./setup.sh
```
A side-remark for DVC version 1 (no longer applies to 2.9.4): The Openstack Swift patch is applied to dvc/tree/s3.py as in https://stackoverflow.com/a/60566758 during the setup, i.e. `config=botocore.client.Config(signature_version='s3')` is added as a parameter to `session.resource()` call in line 80 dvc/tree/s3.py of `dvc[s3]==1.9.1`.

If you're the creator of this repo, run `mkdir data && cd data && dvc init --subdir`. You can disable DVC analytics with `dvc config core.analytics false`.

Create S3 access credentials for DVC with
```
openstack ec2 credentials create
```
and put them in `~/.aws/credentials` as described in the [boto3 docs](https://boto3.amazonaws.com/v1/documentation/api/latest/guide/credentials.html#guide-credentials), i.e. `access` and `secret` into
```
[default]
aws_access_key_id=<openstack-access>
aws_secret_access_key=<openstack-secret>
```

Configure your remote with 
```
dvc remote add --default --verbose castor s3://<name-of-your-castor-bucket>
dvc remote modify --verbose castor endpointurl https://object.cscs.ch
```
according to [this](https://user.cscs.ch/storage/object_storage/) and  [this](https://user.cscs.ch/storage/object_storage/usage_examples/boto/). The `.dvc/config` may look like this

```
[core]
    analytics = false
    remote = castor
['remote "pollux"']
    url = s3://hpc-predict-castor-test
    endpointurl = https://object.cscs.ch
```

You can now run `pip freeze > requirements.txt` and commit the new DVC remote setup to Git with
```
git commit .dvc/config requirements.txt -m "Added <name-of-your-castor-bucket> on Castor as a new DVC remote"
```
When you `git push` this commit, you'll be able to `git clone` it elsewhere, set up the python virtual environment 
```shell
cd data
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip && pip install -r requirements.txt
```
and after making the `.aws/credentials` available will have a working DVC setup. 

For testing purposes you can e.g. create the file `test_in` in data directory and use `dvc add test_in` to track it with DVC. You should now be able to run `dvc push` successfully so that `test_in` can be recovered elsewhere after cloning this Git repo.
