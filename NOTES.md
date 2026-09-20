# xen-riscv-builder

The build environment used to get a container-capable domU running under Xen
on riscv64, as it actually ran, warts included.

## What this is

A copy of `automation/build/debian/trixie-riscv64/` from
[gitlab.com/xen-project/people/olkur/xen](https://gitlab.com/xen-project/people/olkur/xen),
branch `dev-riscv-support-guest-domains`, commit `8bc1c24`
(tag `v1.1.0-riscv-domu-support`), with local edits.

The first commit is that directory **unmodified**, so `git log -p` and
`git diff <first-commit>..HEAD` show exactly what is ours and nothing else.
`README.md` is upstream's and describes upstream's image. This file is ours.

## This is not the thing to upstream

Four of the edits here are genuine defects in the upstream build environment
and were extracted as a reviewable patch series, which lives on a different
branch in a different repository:

> gitlab.com/gounthar/xen, branch `riscv-builder-fixes`, on top of `8bc1c24`

That series is what a maintainer should read. This repository is the working
copy, and the two deliberately disagree in one place:

- **`TOOLS_CONFIG`**. Both fix the same bug: `dist-tools` ran before the
  top-level `config.status` had generated `config/Paths.mk`, so every install
  path expanded to empty and the bash-completion snippet overwrote the `xl`
  binary at the same destination. `make dist` then exited 0 having produced a
  toolstack whose `dist/install/xl` was a 393-byte shell script.
  Both prepend `$(XEN_CONFIG) &&` to fix the ordering. They then diverge:
  here, the cached `config_tools.status` is kept and `CONFIGS_DIR` is pointed
  at a regenerated one (`config_tools_regen.status`); the patch series instead
  drops the cached status and runs `tools/configure` for real, which is the
  better answer upstream and a worse one for iterating locally.

Do not treat this repository as a proposal.

## Which edits are fixes and which are just this experiment

Fixes, and the reason they exist:

- `trixie-riscv64.dockerfile`: `libfdt-dev:riscv64` added (libxl links `-lfdt`
  for `CONFIG_RISCV`); `bash` unpacked into the initrd, because the hotplug
  scripts libxl execs are `#!/bin/bash` and use bash-only syntax on paths that
  always run, so the busybox ash is not a substitute.
- `Makefile`: `/var/log/xen` and `/var/run/xen-hotplug` created, because
  `xen-hotplug-common.sh:23` does `exec 2>>/var/log/xen/xen-hotplug.log` and a
  failed exec redirect kills a non-interactive bash outright; `/usr/local/{bin,sbin,lib}`
  symlinked at the paths `hotplugpath.sh` hardcodes; `/etc/xen/scripts`
  populated, since libxl's compiled-in `XEN_SCRIPT_DIR` points there.
- `Makefile`: `DOMU_KERNEL` split out from `KERNEL`. dom0 and the domU need
  different kernels and these defaulted to the same file.
- `check-initrd-libs.sh` (new): the initrd library list was maintained by hand
  and was never a dependency closure. This walks every ELF in the staged tree
  and fails the build naming any unresolved soname.

Experiment-specific, and meaningless outside this run:

- `-smp 4`, `-m 6g` in the Makefile, and the matching `PLATFORM_PCPU_NUM=4` /
  `PLATFORM_RAM_SIZE=6g` in `generate_dtb.sh`. The machine size lives in
  **both** places and they have to move together.
- `dom0_mem=1024M` moved onto `PLATFORM_XEN_BOOTARGS`. Upstream has it on
  `DOM0_BOOTARGS`, where it is inert: it reaches Linux, not Xen, and Linux
  passes it to init as an environment variable. The value is a power of two on
  purpose, because at `1536M` Xen allocated dom0 in three banks and then
  placed the dom0 initrd past the end of the first one and faulted.
- `domu.cfg`: `memory = 1344`, a `vif` on `xenbr0`, a raw `phy` disk, and the
  payload's own `test=`/`net.`/`k3s.` parameters in `extra`.

## What is not here

`out-initrd/` (235 MB) and `payload/` (354 MB) are build outputs and are
gitignored. They are reproducible from the Makefile and the payload tree.

The `*.orig` files in the working directory are backups of the upstream
versions and are not committed; the first commit serves that purpose.

## Warning about editing these files

`domu.cfg` is baked into the ext2 image at build time and `generate_dtb.sh` is
baked into the container image. Editing the copy on disk changes nothing unless
you rebuild or mount over it. Read a file back with
`debugfs -R "cat ..." <image>`, never `cat` the one on disk.
