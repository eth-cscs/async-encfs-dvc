# DVC patches

## Using environment variables in DVC stages in version 2

A note on the use of environment variables in DVC stages. DVC version 2 interprets `${MY_VAR}` expressions in command or data dependencies of DVC stages as DVC parameters, so this syntax cannot be used to access shell environment variables or similar. If you don't need DVC parameters (or tolerate a top-level `DVC_` prefix to all of them), but want shell environment variables to show up in DVC stage definitions (i.e. `dvc.yaml`), you can modify the [`KEYCRE` variable](https://github.com/iterative/dvc/blob/main/dvc/parsing/interpolate.py#L23) in the string interpolation of DVC's parsing module to e.g.
```python
KEYCRE = re.compile(
    r"""
    (?<!\\)                            # escape \${}
    \${                                # starts with ${dvc_
    (?P<inner>dvc_.*?)                 # match every char inside
    }                                  # end with {
""",
    re.VERBOSE,
)
```
so that only variables starting with `dvc_` (e.g. `${dvc_my_var}`) get expanded with DVC parameters. This change can be done manually in the virtual environment after DVC has been successfully installed.

To restrict DVC parameter expansion in stage commands only to expressions starting with `${dvc_` (instead of requiring `\$`), thus being able to put all other environment variable expressions in the DVC command without being altered by DVC, run the following patch on `dvc/parsing/interpolate.py`,

```shell
patch venv/lib/python*/site-packages/dvc/parsing/interpolate.py "$(git rev-parse --show-toplevel)"/data/dvc_tools/patches/dvc_2_env_variables_parsing_interpolate.patch
```

## S3 patch for DVC version 1 (tested with v1.9.1)

For DVC version 1 (no longer applies to 2.9.4), there is an Openstack Swift patch that can be applied to `dvc/tree/s3.py` as [documented here](https://stackoverflow.com/a/60566758) during the setup, i.e. `config=botocore.client.Config(signature_version='s3')` is added as a parameter to `session.resource()` call in line 80 dvc/tree/s3.py of `dvc[s3]==1.9.1`.


```shell
patch venv/lib/python*/site-packages/dvc/tree/s3.py "$(git rev-parse --show-toplevel)"/data/dvc_tools/patches/dvc_191_openstack_patch.patch
```
