### Pollux DVC test

Set up the repository with

```
./setup.sh
```
An Openstack Swift patch is applied to dvc/tree/s3.py as in https://stackoverflow.com/a/60566758 during the setup, i.e. `config=botocore.client.Config(signature_version='s3')` is added as a parameter to `session.resource()` call in line 80 dvc/tree/s3.py of `dvc[s3]==1.9.1`.

If you're the creator of this repo, run `mkdir data && cd data && dvc init --subdir`. You can disable DVC analytics with `dvc config core.analytics false`.

Create S3 access credentials for DVC with
```
openstack ec2 credentials create
```
and put them in `~/.aws/credentials` as described in the [boto3 docs](https://boto3.amazonaws.com/v1/documentation/api/latest/guide/credentials.html#guide-credentials).

Configure your remote with 
```
dvc remote add --default --verbose pollux <name-of-your-pollux-bucket>
dvc remote modify --verbose pollux endpointurl https://object.cscs.ch
```
according to this [manual](https://user.cscs.ch/storage/object_storage/usage_examples/boto/). The `.dvc/config` may look like this

```
[core]
    analytics = false
    remote = pollux
['remote "pollux"']
    url = s3://hpc-predict-pollux-test
    endpointurl = https://object.cscs.ch
```

For testing purposes you can e.g. create the file `test_in` in data directory and use `dvc add test_in` to track it with DVC. You should now be able to run `dvc push` successfully so that `test_in` can be recovered elsewhere after cloning this Git repo.

You can commit the new remote to Git with 
```
git commit .dvc/config -m "Added Pollux object storage"
```





