# Installing EncFS

The easiest way to install EncFS is with the package manager of your distribution. On Piz Daint, EncFS is already pre-installed at `ENCFS_INSTALL_DIR=${APPS}/UES/anfink/encfs`.

For the installation from source, CMake is required. EncFS can be installed locally by running
```shell
$ ./compile.sh
```
The executable will be available at `install/bin/encfs`.

# Creating an EncFS-managed DVC repository

To set up a DVC environment with EncFS, change to the subdirectory intended as DVC root directory and initialize an EncFS-managed DVC repo

```shell
$ dvc_init_repo . encfs
```

This creates three directories:
 * `encrypt` for the encrypted data managed by DVC
 * `decrypt`, where EncFS mounts a decrypted view of the data
 * `config` for DVC stage files to be committed to Git
All of these have the same hierarchical organization of files into folders.

To configure EncFS, the following configuration is recommended
```shell
$ ${ENCFS_INSTALL_DIR}/bin/encfs -o allow_root,max_write=1048576,big_writes -f encrypt decrypt
Creating new encrypted volume.
Please choose from one of the following options:
 enter "x" for expert configuration mode,
 enter "p" for pre-configured paranoia mode,
 anything else, or an empty line will select standard mode.
?> x

Manual configuration mode selected.
The following cipher algorithms are available:
1. AES : 16 byte block cipher
 -- Supports key lengths of 128 to 256 bits
 -- Supports block sizes of 64 to 4096 bytes
2. Blowfish : 8 byte block cipher
 -- Supports key lengths of 128 to 256 bits
 -- Supports block sizes of 64 to 4096 bytes
3. CAMELLIA : 16 byte block cipher
 -- Supports key lengths of 128 to 256 bits
 -- Supports block sizes of 64 to 4096 bytes

Enter the number corresponding to your choice: 1

Selected algorithm "AES"

Please select a key size in bits.  The cipher you have chosen
supports sizes from 128 to 256 bits in increments of 64 bits.
For example: 
128, 192, 256
Selected key size: 256

Using key size of 256 bits

Select a block size in bytes.  The cipher you have chosen
supports sizes from 64 to 4096 bytes in increments of 16.
Or just hit enter for the default (1024 bytes)

filesystem block size: 4096

Using filesystem block size of 4096 bytes

The following filename encoding algorithms are available:
1. Block : Block encoding, hides file name size somewhat
2. Block32 : Block encoding with base32 output for case-insensitive systems
3. Null : No encryption of filenames
4. Stream : Stream encoding, keeps filenames as short as possible

Enter the number corresponding to your choice: 3

Selected algorithm "Null""

Enable filename initialization vector chaining?
This makes filename encoding dependent on the complete path, 
rather then encoding each path element individually.
[y]/n: y

Enable per-file initialization vectors?
This adds about 8 bytes per file to the storage requirements.
It should not affect performance except possibly with applications
which rely on block-aligned file io for performance.
[y]/n: y

Enable filename to IV header chaining?
This makes file data encoding dependent on the complete file path.
If a file is renamed, it will not decode sucessfully unless it
was renamed by encfs with the proper key.
If this option is enabled, then hard links will not be supported
in the filesystem.
y/[n]: y

Enable block authentication code headers
on every block in a file?  This adds about 8 bytes per block
to the storage requirements for a file, and significantly affects
performance but it also means [almost] any modifications or errors
within a block will be caught and will cause a read error.
y/[n]: n

Add random bytes to each block header?
This adds a performance penalty, but ensures that blocks
have different authentication codes.  Note that you can
have the same benefits by enabling per-file initialization
vectors, which does not come with as great of performance
penalty. 
Select a number of bytes, from 0 (no random bytes) to 8: 0

Enable file-hole pass-through?
This avoids writing encrypted blocks when file holes are created.
[y]/n: y


Configuration finished.  The filesystem to be created has
the following properties:
Filesystem cipher: "ssl/aes", version 3:0:2
Filename encoding: "nameio/null", version 1:0:0
Key Size: 256 bits
Block Size: 4096 bytes
Each file contains 8 byte header with unique IV data.
Filenames encoded using IV chaining mode.
File data IV is chained to filename IV.
File holes passed through to ciphertext.

-------------------------- WARNING --------------------------
The external initialization-vector chaining option has been
enabled.  This option disables the use of hard links on the
filesystem. Without hard links, some programs may not work.
The programs 'mutt' and 'procmail' are known to fail.  For
more information, please see the encfs mailing list.
If you would like to choose another configuration setting,
please press CTRL-C now to abort and start over.

Now you will need to enter a password for your filesystem.
You will need to remember this password, as there is absolutely
no recovery mechanism.  However, the password can be changed
later using encfsctl.

New Encfs Password: 
Verify Encfs Password:
```
The configuration will be stored in a file `encrypt/.encfs6.xml` and should look similar to 

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE boost_serialization>
<boost_serialization signature="serialization::archive" version="7">
    <cfg class_id="0" tracking_level="0" version="20">
        <version>20100713</version>
        <creator>EncFS 1.9.5</creator>
        <cipherAlg class_id="1" tracking_level="0" version="0">
            <name>ssl/aes</name>
            <major>3</major>
            <minor>0</minor>
        </cipherAlg>
        <nameAlg>
            <name>nameio/null</name>
            <major>1</major>
            <minor>0</minor>
        </nameAlg>
        <keySize>256</keySize>
        <blockSize>4096</blockSize>
        <plainData>0</plainData>
        <uniqueIV>1</uniqueIV>
        <chainedNameIV>1</chainedNameIV>
        <externalIVChaining>1</externalIVChaining>
        <blockMACBytes>0</blockMACBytes>
        <blockMACRandBytes>0</blockMACRandBytes>
        <allowHoles>1</allowHoles>
        <encodedKeySize>52</encodedKeySize>
        <encodedKeyData>
...
</encodedKeyData>
        <saltLen>20</saltLen>
        <saltData>
...
</saltData>
        <kdfIterations>...</kdfIterations>
        <desiredKDFDuration>500</desiredKDFDuration>
    </cfg>
</boost_serialization>
```

# Using EncFS with DVC on a single node

Before interacting with encrypted data, EncFS must mount a decrypted view of the data in `encrypt`. Execute the following command in the DVC root directory.
```shell
ENCFS_PW_FILE=<path-to-encfs.key> encfs_launch .dvc_policies/repo/dvc_root.yaml 
```
This runs EncFS in the foreground and allows you to access the data through the EncFS-mounted target directory `decrypt` in another shell, e.g. to run a DVC stage on a single node or to inspect results of a previously run stage. As EncFS is run in the foreground it can be interrupted when you're done. 

On Piz Daint, the decrypted view is made available on `/tmp/encfs_$(id -u)_async_encfs_dvc` as an EncFS-mount in other locations than `/tmp` is not allowed - this path should be made DVC-repo-specific if multiple EncFS-repos are used.

# Running SLURM jobs with EncFS and DVC

To run EncFS-jobs with SLURM on Piz Daint manually, you can wrap the rank-specific part of your `srun`-command in the script `encfs_mount_and_run` plus the EncFS-root and mount target directory. This will mount your `encrypt` directory at `<decrypt-dir>` (typically `/tmp/encfs_$(id -u)_async_encfs_dvc`) on each compute node using the EncFS-password in `${ENCFS_PW_FILE}` for the duration of the command,

```shell
ENCFS_PW_FILE=<path-to-encfs.key> srun encfs_mount_and_run encrypt <decrypt-dir> <log-file> <command>
```

You can run application stages of a pipeline on sensitive data through Sarus (providing the extra `SARUS_ARGS=env` environment) and bind-mount the decrypted directory to make it available within the container, e.g. by appending the following command to the above `srun` line,
```shell
sarus run --mount=type=bind,source=<decrypt-dir>,destination=/app-data ...
```
This makes the decrypted view of the data in `encrypt` available at the mounted path `/app-data` within the container of each SLURM MPI-rank. The `...` are the usual arguments, such as ` --mpi --entrypoint bash <image-name:tag> -c '<command-to-execute>'`.

To ease the user experience, these commands are automatically generated from DVC policies when using the EncFS repo policy and specifying a container engine in the app policy.