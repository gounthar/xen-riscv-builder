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
  placed the dom0 initrd past the end of the first one and faulted. That is
  this branch's `place_modules()`, fixed upstream in `staging` (`f6a20eda`);
  see "K3s state on the PV disk" below for the backport that boots 3072M.
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

### K3s state on the PV disk: `DISK_MB`, `K3S_DISK`, `WAIT_LOG`, `DOM0_MEM`

Four knobs added for the payload's `k3s.disk=1` (runs 52-56):

| variable | default | what it does |
|---|---|---|
| `DISK_MB` | 64 | size of `/mnt/disk.img` in dom0. 64 is written out as zeros as before; anything larger is created sparse, so dom0's tmpfs only pays for blocks the guest writes. `TMPFS_MB` defaults to `DISK_MB + 32` |
| `K3S_DISK` | 0 | adds `k3s.disk=1` to `domu.cfg`; with `MULTINODE=1`, gives the server guest (`domu-mn.cfg`) a disk stanza and `k3s.disk=1`, and leaves the agent on tmpfs. Needs `WITH_DISK=1` and `DISK_MB` above 64: K3s used 159M of 512 at `K3S_OK` |
| `WAIT_LOG` | unset | path of this run's own log on the host. The driver waits for `reboot: Power down` in it, sends `^]` to detach from the guest's console, then types the post-run commands (dom0 tmpfs usage, hotplug log). `POSTCREATE` stays the upper bound |
| `DOM0_MEM` | 1024M | read by `generate_dtb.sh`, goes on Xen's command line. Leave it at 1024M, see below |

`WAIT_LOG` exists because nothing typed after `xl create -c` had ever reached dom0: once the
attached guest powers off, the console stays attached to the dead guest (runs 24, 30, 36 end
at `Power down` with none of the post-run output). It keys on the power-down line rather
than a timer, because detaching early loses the guest's output.

The runs were chained by a small script kept on fedora1 only, `~/xen-run/kdisk-series.sh`
(not in this repo): `bash kdisk-series.sh 57:1 58:1` runs 57 and 58 with `MULTINODE=1`
(`N:0` for one domU) and `WITH_DISK=1 DISK_MB=512 K3S_DISK=1 WAIT_LOG=<its log>`, stops each
run itself, and appends a `runN kdisk ...` line per run and `KDISK_SERIES_DONE` to
`repeat2.log`.

Two more serial traps, one run each:

- **dom0's serial input drops characters under load.** Type one short line at a time with a
  gap, under about 60 characters. Run 53 sent four post-run commands back to back and the last
  arrived as `echo -`, so its end marker never printed. Run 55 typed the server's 150-character
  disk stanza as one line and it arrived as `>> cat /domu/domu-mn.cfg`: the guest booted
  without a disk and the run was aborted. Both are now short lines with a gap.
- **`rc=0` does not prove a config edit landed.** A mangled `sed` or `echo` can still exit
  0. The proof is the config printed back, or a `grep -c` of the line you added.

**`DOM0_MEM=3072M` faults while loading dom0 (run 51).** Xen gave dom0 three banks,
0x88000000 (128M), 0xa0000000 (384M) and 0xc0000000 (2.5G), and the 244 MiB dom0 initrd was
placed at 0x89e00b34-0x99224b34, across the end of the 128M bank; the fault is in the copy.
At 1024M dom0 gets one bank at 0xc0000000 and boots. The source explains it: in the Xen
branch this builds (`dev-riscv-support-guest-domains`), `place_modules()` in
`xen/arch/riscv/kernel.c` leaves the initrd out of its size check and places it right after
the DTB without checking that it fits in bank 0. Upstream `staging` rewrote that function in
`f6a20eda` (2026-05-19) to count the initrd and pick a bank that holds it. Backported into a
copy of the tree (`~/xen-riscv/xen-pm`, binary `530f466eeebe`), 3072M boots with the initrd
at `0x150bdc000-0x160000000` inside the top bank (run 59). Logs:
`~/xen-riscv/xen-domu-run51-DOM0MEM3072-FAULT.log`,
`~/xen-riscv/xen-domu-run59-DOM0MEM3072-BOOTS-THEN-PERCPU-ASSERT.log`.

**A run can hang on a Xen assertion that parks the CPU (runs 57, 59).** Under PV disk I/O,
`Assertion this_cpu_ptr(per_cpudata) != NULL failed at ./include/xen/rwlock.h:369`: the guest
stops, dom0 carries on, and the driver waits until `POSTCREATE` or the series cap
(`kdisk-series.sh` stops at 5400 s). Grep the log for `Assertion` before reading a timeout
as a slow guest. The likely cause is this branch's riscv `this_cpu_ptr()`, which offsets by
the CPU number; `staging` defines it correctly. Not yet tested.

**Over ssh, do not `pgrep -f xen-run2.sh` and kill what it finds**: the pattern matches the
ssh command line itself, and the cleanup kills its own shell halfway.

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
