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

The edits here that fix genuine defects in the upstream build environment were
extracted as a reviewable patch series, which lives on a different branch in a
different repository:

> gitlab.com/gounthar/xen, branch `riscv-builder-fixes`, seven commits on top of
> `8bc1c24` (head `18e92d1e25`, 2026-09-21)

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
  and fails the build naming any unresolved soname. It cannot see dlopen'd
  libraries, which is how the next one was missed.
- `trixie-riscv64.dockerfile`: `libgcc_s.so.1` copied into the initrd. glibc
  dlopens it for `pthread_cancel`, which `libxenstore` reaches, so `xl` aborted
  after creating the domain.
- `Makefile`, dom0 rcS: `/dev/fd` and `/dev/std{in,out,err}` linked into
  `/proc/self/fd`, and devpts mounted. The kernel mounts a bare devtmpfs on
  `/dev`; `claim_lock` in `locking.sh` stats `/dev/stdin` and loops forever
  without it (every `block` hotplug timed out), and `xenconsoled` needs devpts
  for `openpty()`. Made at boot because devtmpfs hides anything under `/dev` in
  the image.

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
  payload's own `test=`/`net.`/`k3s.` parameters in `extra` (including
  `k3s.cfgtimeout=1800`, because 120 s is not enough under Xen on TCG), plus an
  explicit `type = "pvh"`.
- `loglvl=all guest_loglvl=all` on Xen's command line: debug output, drop it
  before reusing anything here.
- `cfg-regen/`: a `CONFIGS_DIR` whose `config_tools.status` was regenerated for
  this tree (the committed one has no fdt probes and fails with an
  `fdt_property_u32` redefinition).
- `run/`: the drivers that type into dom0's console one command at a time and
  print `STEP<n>:<name>:rc=<status>` after each. `RCS_DEVFIX=1` makes
  `xen-run2.sh` only check the `/dev/fd` links and devpts instead of creating
  them, which is how the rcS change above was verified (four runs, 2026-09-21).

## The run drivers, and the four modes

`run/xen-run2.sh` types into dom0's console one command at a time and prints
`STEP<n>:<name>:rc=<status>` after each, so silence names the command it died on. Four
modes, selected by environment variable:

| mode | what it does | guest configs used |
|---|---|---|
| default | one domU, console attached | `domu.cfg` |
| `TRACE=1` | one domU, created detached, then `xl list`/`vcpu-list`/`debug-keys` | `domu.cfg` |
| `NETCHECK=1` | one domU, detached, dom0 pings it across `xenbr0` | `domu.cfg` |
| `MULTINODE=1` | two domUs: agent detached, server attached; two-node K3s | `domu2.cfg`, `domu-mn.cfg` |
| `PINGPAIR=1` | two domUs, no K3s: one pings the other with 1000-byte frames | `domu-ping-a.cfg`, `domu-ping-b.cfg` |

`PINGPAIR` exists to isolate one thing: a frame large enough to be grant-mapped between two
guests reaches `page_get_owner_and_reference()`, an `assert_failed()` stub in
`xen/arch/riscv/mm.c`. With ARM's one-line definition of that wrapper the ping is 5/5; with
the stub it asserts at the first ping (runs 49 and 50, same image, only the Xen binary
differing). Dom0-to-guest traffic never takes that path.

### Three things that cost a run each, in the two-domU modes

Worth knowing before writing another mode that types into dom0's console:

- **Do not type a long line while a guest is booting.** In `MULTINODE` the second domain's
  `earlycon` output floods the same serial console. A ~300-character line lost characters,
  the shell sat at a `>` continuation prompt, and it swallowed the next command (run 40).
  The driver now sleeps `AGENT_SETTLE` (60 s) on the host after the first create, and writes
  anything long as short lines with their own markers.
- **dom0's image has no `/tmp`.** Scratch files go in `/mnt`, the tmpfs the driver mounts
  itself (run 41).
- **A powered-off domU never leaves `xl list`**, because `domain_relinquish_resources()`
  returns `-ENOSYS` on riscv. Anything that waits for a domain to disappear hangs; wait for a
  marker in `xenconsoled`'s per-guest log instead (run 43). Only one guest's console can be
  attached, so `MULTINODE` starts `xenconsoled` with `--log=guest --log-dir=/var/log/xen/console`
  and prints the other guest's log from a dom0 background job.

## What is not here

`out-initrd/` (235 MB), `payload/` and `payload-mn/` (354 MB each) are build
outputs and are gitignored. They are reproducible from the Makefile and the payload tree.

The `*.orig` files in the working directory are backups of the upstream
versions and are not committed; the first commit serves that purpose.

## Warning about editing these files

The guest configs (`domu.cfg` and now `domu-mn.cfg`, `domu2.cfg`, `domu-ping-a.cfg`,
`domu-ping-b.cfg`, all copied by the `domu*.cfg` glob) are baked into the ext2 image at build
time and `generate_dtb.sh` is baked into the container image. Editing the copy on disk changes nothing unless
you rebuild or mount over it. Read a file back with
`debugfs -R "cat ..." <image>`, never `cat` the one on disk.
