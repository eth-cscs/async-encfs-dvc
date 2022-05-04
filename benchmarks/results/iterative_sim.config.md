# iterative_sim benchmarks on Piz Daint

The subdirectories/zip-archives contain the log-files for the runs with different sizes/amounts of files per rank on Piz Daint. The software environment for the measurements was

```
$ module list
Currently Loaded Modulefiles:
  1) modules/3.2.11.4                                16) atp/3.14.5
  2) craype-network-aries                            17) perftools-base/21.09.0
  3) cce/12.0.3                                      18) PrgEnv-cray/6.0.10
  4) craype/2.7.10                                   19) cray-mpich/7.7.18
  5) cray-libsci/20.09.1                             20) slurm/20.11.8-2
  6) udreg/2.3.2-7.0.3.1_2.15__g5f0d670.ari          21) craype-haswell
  7) ugni/6.0.14.0-7.0.3.1_3.10__gdac08a5.ari        22) tree/1.8.0
  8) pmi/5.0.17                                      23) ncurses/.6.1
  9) dmapp/7.1.1-7.0.3.1_2.21__g93a7e9f.ari          24) htop/2.2.0
 10) gni-headers/5.0.12.0-7.0.3.1_2.9__gd0d73fe.ari  25) libevent/.2.1.8
 11) xpmem/2.2.27-7.0.3.1_2.8__gada73ac.ari          26) tmux/2.9
 12) job/2.2.4-7.0.3.1_2.16__g36b56f4.ari            27) daint-gpu/21.09
 13) dvs/2.12_2.2.224-7.0.3.1_2.20__gc77db2af        28) cray-python/3.9.4.1
 14) alps/6.6.67-7.0.3.1_2.20__gb91cd181.ari         29) sarus/1.4.2
 15) rca/2.2.20-7.0.3.1_2.20__g8e3fb5b.ari

(venv) $ pip freeze  # in the Python 3 virtual environment
aiobotocore==2.2.0
aiohttp==3.8.1
aiohttp-retry==2.4.6
aioitertools==0.10.0
aiosignal==1.2.0
appdirs==1.4.4
async-timeout==4.0.2
asyncssh==2.10.1
atpublic==3.0.1
attrs==21.4.0
autopage==0.5.0
Babel==2.10.1
boto3==1.21.21
botocore==1.24.21
certifi==2021.10.8
cffi==1.15.0
charset-normalizer==2.0.12
cliff==3.10.1
cmd2==2.4.1
colorama==0.4.4
commonmark==0.9.1
configobj==5.0.6
cryptography==36.0.2
debtcollector==2.5.0
decorator==5.1.1
dictdiffer==0.9.0
diskcache==5.4.0
distro==1.7.0
dogpile.cache==1.1.5
dpath==2.0.6
dulwich==0.20.35
dvc==2.10.1
dvc-render==0.0.4
flatten-dict==0.4.2
flufl.lock==7.0
frozenlist==1.3.0
fsspec==2022.3.0
ftfy==6.1.1
funcy==1.17
future==0.18.2
gitdb==4.0.9
GitPython==3.1.27
grandalf==0.6
idna==3.3
iso8601==1.0.2
Jinja2==3.1.1
jmespath==1.0.0
jsonpatch==1.32
jsonpointer==2.3
keystoneauth1==4.5.0
lxml==4.8.0
mailchecker==4.1.15
MarkupSafe==2.1.1
msgpack==1.0.3
multidict==6.0.2
munch==2.5.0
nanotime==0.5.2
netaddr==0.8.0
netifaces==0.11.0
networkx==2.8
oauthlib==3.2.0
openstacksdk==0.61.0
os-service-types==1.7.0
osc-lib==2.5.0
oslo.config==8.8.0
oslo.i18n==5.1.0
oslo.serialization==4.3.0
oslo.utils==4.12.2
packaging==21.3
pathspec==0.9.0
pbr==5.8.1
phonenumbers==8.12.47
prettytable==3.2.0
psutil==5.9.0
pycparser==2.21
pydot==1.4.2
pygit2==1.9.1
Pygments==2.12.0
pygtrie==2.4.2
pyparsing==3.0.8
pyperclip==1.8.2
python-benedict==0.25.0
python-cinderclient==8.3.0
python-dateutil==2.8.2
python-fsutil==0.6.0
python-heatclient==2.5.1
python-keystoneclient==4.4.0
python-novaclient==17.7.0
python-openstackclient==5.8.0
python-slugify==6.1.1
python-swiftclient==3.13.1
pytz==2022.1
PyYAML==6.0
requests==2.27.1
requestsexceptions==1.4.0
rfc3986==2.0.0
rich==12.2.0
ruamel.yaml==0.17.21
ruamel.yaml.clib==0.2.6
s3fs==2022.3.0
s3transfer==0.5.2
scmrepo==0.0.16
shortuuid==1.0.8
shtab==1.5.4
simplejson==3.17.6
six==1.16.0
smmap==5.0.0
stevedore==3.5.0
tabulate==0.8.9
text-unidecode==1.3
toml==0.10.2
tqdm==4.64.0
typing_extensions==4.2.0
urllib3==1.26.9
voluptuous==0.13.1
wcwidth==0.2.5
wrapt==1.14.0
xmltodict==0.12.0
yarl==1.7.2
zc.lockfile==2.0
```
