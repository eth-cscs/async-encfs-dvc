# Setting up a new DVC repository with Castor and EncFS

This is a step-by-step guide for setting up a DVC repository in a subdirectory with Castor and (optionally) encryption. We will use `examples/data/v0` for this purpose, although the subdirectory can be chosen arbitrarily.

## Step 1: Create a Python environment with async_encfs_dvc

We first change to the desired subdirectory that you would like to manage with DVC
```shell
mkdir -p examples/data/v0 && cd examples/data/v0
```

For Ubuntu, we install Python, create a virtual environment and install the package therein.
```shell
# https://docs.openstack.org/newton/user-guide/common/cli-install-openstack-command-line-clients.html
sudo apt install python3-dev python3-pip
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install git+https://github.com/eth-cscs/async-encfs-dvc.git
```

This will install `async_encfs_dvc` and all its dependencies including DVC and Openstack Swift.

## Step 2: Generate access credentials for the OpenStack Swift object storage

Every new user of the DVC repository on Castor needs to create S3 access credentials. Set up an OpenStack CLI environment for Castor by first setting the environment variable
```shell
ETH_CSCS_OPENSTACK="$(python -c 'from async_encfs_dvc import openstack; print(openstack.__path__[0])')"
```
If you are using multifactor-authentication, you can then run
```shell
source "${ETH_CSCS_OPENSTACK}/cli/castor-cli-otp.env"
```
otherwise
```shell
source "${ETH_CSCS_OPENSTACK}/cli/castor.env"
```
This will ask you to log in to Castor and specify your project account. Then you can create EC2 credentials using
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
Here, `<aws-profile-name>` is a placeholder and it is recommended to use the name of your project in `castor.cscs.ch`. If this is not possible, you can also put the credentials under a different block (using e.g. `default` as the AWS profile name).

## Step 3: Initializing the DVC directory to track your data

The following steps only have to be performed once per project. To set up a subdirectory in `examples/data/v0` for tracking workflow results with DVC, in that directory run 

```shell
dvc_init_repo . <repo-policy>
```
You will now have an empty directory, whose contents are tracked by DVC, but not yet synchronized with remote storage. In addition, it is pre-configured for the `<repo-policy>`, which can take the values of `plain` for an unencrypted or `encfs` for an EncFS-managed repository. This is stored in `.dvc_policies/repo/dvc_root.yaml`. In case you choose to use encryption, as a next step follow the [EncFS initialization instructions](../async_encfs_dvc/encfs_int/README.md) to obtain a configuration file under the directory `encrypt`. As a last item, `dvc_init_repo` places a set of default stage policies are available under `.dvc_policies/stages` that can be continuously adapted and extended as the project evolves.

Now, go to https://castor.cscs.ch and create an object storage container on under the appropriate project account to mirror the contents of the `examples/data/v0` directory (e.g. use `<git-repo-name-examples-data-v0>`). Then, back to the command line, configure your Castor as a DVC remote with 
```shell
dvc remote add --default --verbose castor s3://<name-of-your-castor-bucket>
dvc remote modify --verbose castor endpointurl https://object.cscs.ch
dvc remote modify --verbose castor acl authenticated-read
dvc remote modify --verbose castor profile <aws-profile-name>
```
according to the CSCS user documentation on [object storage](https://user.cscs.ch/storage/object_storage/) and the [boto client](https://user.cscs.ch/storage/object_storage/usage_examples/boto/). The third command is necessary if the newly created AWS credentials have been put under an `<aws-profile-name>` above that is not `default`.

The `.dvc/config` should now look like this

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

## Step 4: Restoring the DVC repo on a different machine

You can now commit the above DVC environment to Git in order to regenerate it on a different machine. This includes the DVC configuration shown above, but also the `async_encfs_dvc` DVC policies and - if using encryption - also the EncFS configuration file inside `encrypt` created during [EncFS initialization](../async_encfs_dvc/encfs_int/README.md).

```shell
git add .dvc/config .dvc_policies encrypt/.encfs6.xml
git commit -m "Added initial DVC repo configuration with remote S3 bucket <name-of-your-castor-bucket> on Castor"
```

When you `git push` this commit, you will be able to `git clone` the repository on another machine, set up the python environment as in step 1,

```shell
cd examples/data/v0
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install git+https://github.com/eth-cscs/async-encfs-dvc.git
```
and will have a working DVC setup (e.g. using `dvc pull <target-name>` will pull files from Castor).

If you would like to regenerate the exact same Python environment on all machines, you can e.g. use `pip freeze > requirements.txt` on the first machine, commit this along with the `.dvc/config` and replace `async_encfs_dvc` installation line above by running `pip install -r requirements.txt` on all others.

## Step 5 (optional): Details on S3-object storage management

### Configuration for large files

Depending on your requirements (file sizes, etc.), you may find that you need to configure the S3 transfers appropriately, cf. the "S3 Custom command settings" available in the [AWS_CONFIG_FILE](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html). As an example, the following configuration will increase the maximum transferable file size to 128 GB,

```
[profile <aws-profile-name>]
s3 =
  multipart_threshold = 256MB
  multipart_chunksize = 128MB
```

This configuration can be stored under `$(dvc root)/.aws_config` and needs to be available to DVC as an environment variable, i.e. in our example run

```shell
export AWS_CONFIG_FILE=$(realpath $(dvc root)/.aws_config)
```

from within `examples/data/v0`.


### Cleanup: Deleting object storage containers on Castor

When the data stored on Castor is no longer required, you can delete the associated object storage containers from within the castor environment
```shell
source "${ETH_CSCS_OPENSTACK}/cli/castor-cli-otp.env"
```
where we used the environment variable set above, and use the OpenStack swift client to
```shell
swift post <name-of-your-castor-bucket>+segments -H 'X-History-Location:'
swift delete <name-of-your-castor-bucket>
swift delete <name-of-your-castor-bucket>_versions
swift delete <name-of-your-castor-bucket>+segments
swift delete <name-of-your-castor-bucket>+segments_versions
```