#!/bin/bash


# https://docs.openstack.org/newton/user-guide/common/cli-install-openstack-command-line-clients.html
# sudo apt install python3-dev python3-pip

python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip

echo "Installing Openstack client"
pip install python-openstackclient lxml oauthlib python-swiftclient python-heatclient

echo "Installing DVC"
pip install dvc[s3]

# This was required in dvc[s3]==1.9.1, but no longer is (dvc[s3]==2.9.4)
# Apply Openstack patch to dvc/tree/s3.py as in https://stackoverflow.com/a/60566758
# i.e. insert config=botocore.client.Config(signature_version='s3') as a parameter to 
# session.resource()` call in line 80 dvc/tree/s3.py of dvc[s3]==1.9.1
# patch venv/lib/python*/site-packages/dvc/tree/s3.py dvc_191_openstack_patch.patch

echo "Run 'source venv/bin/activate' to use the virtual environment with the openstack client and DVC"
