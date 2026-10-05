# NVIDIA Driver Merger
A script to merge generic and vGPU drivers into a single one.

> [!NOTE]
> The version in each branch name is the highest version between the two drivers being merged, and represents the output driver's version. \
> Testing has only been done on these versions — older/newer drivers may work, but it's not guaranteed to build a working merged driver.

## Credits
This script is heavily based on the work done by **[benjamindoron](https://github.com/benjamindoron/vGPU-Unlock-Patcher)**; only the parts not essential to the merge process were removed.

In addition to the above:
- `unlock` system is provided by **[rbqvq](https://github.com/rbqvq/vgpu_unlock-rs)**
- vGPU blob patch was made by reverse-engineering **[GreenDam](https://gitlab.com/GreenDamTan/vgpu-proxmox)**'s work

## Requirements
In order to run this script it is necessary to have installed:
- `patch`
- `binutils`, which provides the `objcopy` and `size` utilities

Other than the ones listed above, you may also need:
- if you need to unlock the driver (via the `-p`/`--patch` option):
    - `patchelf`
    - `cargo` (if installed without using your distribution's package manager, `gcc` is also required)
- if you need to repack the driver (via the `-r`/`--repack` option):
    - `zstd` (this is not required but highly recommended to reduce the final _.run_ file size)
> [!NOTE]
> If the `zstd` command cannot be found, NVIDIA's makeself will fall back to `gzip` compression.

## Usage
1. clone the repository using
    ```shell
    git clone --branch <version> <repo-url>
    ```
    check branch names for the correct _version_ to use;
    - in case you need the merged driver to also be patched, include the `--recursive` option to also clone the unlocker repo, or use
        ```shell
        git submodule update --init
        ```
        if you already cloned without it;
2. copy the drivers to be merged in the same directory as the script;
3. run the following command (check [options](#options))
    ```shell
    ./merge.sh [OPTIONS]
    ```
4. success is indicated by:
    - no errors in the script's output;
    - if the `-r`/`--repack` option was used, a _.run_ driver file.

### Options
The main behavior of `merge.sh` is to merge the two drivers, but it can also do other things when passed the following options:
```text
-p, --patch             patches the vGPU-side of the driver
                        to be used with consumer-grade (unsupported) cards
-r, --repack            creates a .run file that contains the driver
                        (mainly used if the driver was made
                        on a system different from the destination one)
-k, --keep-directories  skip workspace cleaning when finished
-v, --verbose           print makeself output during .run creation
```

## Extra
### CUDA
By default, CUDA is enabled in the merged driver.
If for whatever reason this needs to be changed, it can be done at boot time by making a custom boot entry, or using `modprobe` by editing `/etc/modprobe.d/cuda.conf` to contain:
```text
options nvidia cuda=0
```

### LXC containers
For LXC containers to correctly use the GPU's CUDA features (and consequently NVDEC and NVENC), the device nodes must be created before the first container starts. \
To solve this, and to avoid doing it manually when containers are configured to start at boot, this script adds a systemd service that creates the device nodes automatically.
> [!NOTE]
> The service was created for Proxmox. On a different host OS, check that `/usr/lib/systemd/system/nvidia-dev-init.service` is compatible with your system.

## Troubleshooting
For any type of support needed, join the [Discord server](https://discord.gg/5rQsSV3Byq).

## License
This project is licensed under [AGPLv3-or-later](LICENSE).

When the `-p`/`--patch` option is used, the script builds and integrates [vgpu_unlock-rs](https://github.com/rbqvq/vgpu_unlock-rs), included as a git submodule and distributed under its own MIT license.