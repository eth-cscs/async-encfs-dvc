from setuptools import setup, find_packages

# TODO: Compile and install EncFS if not available

setup(
    name='async-encfs-dvc',
    url='https://github.com/eth-cscs/async-encfs-dvc',
    author='CSCS Swiss National Supercomputing Centre',
    author_email='lukas.drescher@cscs.ch, andreas.fink@cscs.ch',
    description='Privacy-preserving HPC workflows with DVC, EncFS, SLURM and Openstack Swift',
    packages=find_packages(
        exclude=(
            'examples',
        )),    
    install_requires=[
        # 'openstack @ git+https://github.com/eth-cscs/openstack.git # managed through package_data
        'python-openstackclient',
        'lxml',
        'oauthlib',
        'python-swiftclient',
        'python-heatclient',
        'jinja2',
        'dvc[s3] @ git+https://github.com/lukasgd/dvc.git@fix_interpolate_env_var',
    ],
    extras_require={},
    include_package_data=True,
    scripts=[
        'async_encfs_dvc/dvc_init_repo',
        'async_encfs_dvc/dvc_cmd',
        'async_encfs_dvc/encfs_int/encfs_launch',
        'async_encfs_dvc/encfs_int/encfs_mount_and_run',
        'async_encfs_dvc/slurm_int/slurm_enqueue.sh',
        'async_encfs_dvc/slurm_int/dvc_scontrol',
    ],
    entry_points = {
        'console_scripts': ['dvc_create_stage=async_encfs_dvc.dvc_create_stage:main']
    }
)