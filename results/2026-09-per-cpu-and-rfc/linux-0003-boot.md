# Does Linux RFC 0003 "detect Xen from the device tree" still find Xen? (2026-09-24/25)

0003 is the one patch in the Linux RFC series of 2026-09-24 that had never run under Xen;
its commit message says it was only boot-tested on the no-Xen path (plain QEMU virt). This note
runs it under Xen. Tags: [ran it] = run by me tonight; [read source]; [read log]; [inference].
Everything here is QEMU TCG on an x86_64 host (fedora1), nothing on riscv64 hardware.

**Short answer:** yes, both ways, and it stays quiet without Xen (test C). With 0003 in the domU (run 134) and with 0003 in dom0 (run 136)
the kernel prints `Xen 4.18 support found` and the run ends `SUMMARY: docker=ok k3s=ok disk=ok`.
Run 135 (0003 in dom0 on base Xen) detected Xen too, then hit the known intermittent base-Xen
per-cpu assertion; run 136 repeated it on the Xen build that has not shown that assertion.
One run per case: a result, not a rate.

## What the source says [read source]

- 0003's `fdt_find_hyper_node()` looks for a depth-1 node named `hypervisor` with compatible
  `xen,xen`, and takes the version from the `xen,xen-` prefix. On success `xen_early_init()`
  prints `Xen <version> support found`; otherwise the kernel stays XEN_NATIVE quietly.
- domU device tree: libxl `tools/libs/light/libxl_riscv.c:439-447` writes node `hypervisor`,
  compatible `xen,xen-<maj>.<min>` then `xen,xen`.
- dom0 device tree: `xen/arch/riscv/domain_build.c` `make_hypervisor_node()` (line 756) writes
  compatible `"xen,xen-" XEN_VERSION_STRING` then `xen,xen`, under `fdt_begin_node(fdt, "hypervisor")`
  (line 780). So both paths should match; runs 134/135 check it.

## Inputs [ran it]

- Guest kernel: `gounthar/linux-xen-riscv` branch `rfc/domu-guest-2026-09-25` at `79db70fe3a`
  (= baptleduc `048308d86` + RFC 0001 evtchn + 0002 gnttab + 0003 DT detection), exported with
  `git archive`, `xen_defconfig` + `guest-kernel/container.config`. Cross build, tuxmake
  `riscv_gcc-14` on the amd64 laptop: 10m19s wall from scratch (CPU time not captured: `time`
  measured only the docker client), exit 0, 7 warnings (same count as the 2026-09-24 build).
  `Image.gz` sha256 `79318495d69f2cc198e624a905ef42f9e654b9116d9fe58de17ddf13594974e1`.
- Before 0003 the guest kernel that ran in runs 30-133 was `048308d86` + 0001 + 0002.
- dom0 image `initrd-tools-dt.img` (sha256 prefix `fe50fd768783`), built 41.9 s from the
  base tools tree. Checked with `debugfs` against `initrd-tools-restart.img` (run 117):
  only `/domu/Image.gz` differs; `/domu/initrd.img` (payload, `bb4110f6a505`) and `/domu/domu.cfg`
  are byte-identical.
- Xen: `08074f7f22ee` (built 2026-09-22), the hypervisor fedora1 has run since 16:07 on 09-24.
  Run 117 used a different build (`be26eee`/`4307f2165ce4`, 2026-09-23); irrelevant to a pass, but
  it would matter when comparing a failure line by line against 117.
- dom0 kernel for run 134: unchanged, clean `048308d86` + `dom0.config` (sha256 prefix `ee3b68e3`).

## Run 134, test A: 0003 in the domU, dom0 unchanged [ran it]

`bash run/restart-one.sh 134 $HOME/xen-run/initrd-tools-dt.img` (single domU,
RCS_DEVFIX WITH_DISK K3S_DISK, one vCPU, no restart). Wall 576 s.

Result: **pass**. From the log [read log]:

- The second kernel in the log is our build (`root@c9819bac8b49 ... #1 SMP Thu Sep 24 20:20:20
  UTC 2026`, the same string as the built vmlinux) and prints `Xen 4.18 support found`. The dom0
  kernel (no 0003) does not print that line, as expected.
- `Grant table initialized`, netfront up, `blkfront: xvda` with persistent grants, guest initmem
  2440K.
- eth0 192.168.128.2/24 with a default route; ext4 on `/dev/xvda`; `DOCKER_OK`; K3s state moved
  to `/dev/xvda`; `K3S_OK` at 270 s guest time; `SUMMARY: docker=ok k3s=ok disk=ok`.

Log: `logs/dt/xen-domu-run134-DT-DOMU.log` (sha256 prefix `3c1204d22565`).

### A first attempt that tested nothing

The first launch passed the image as a bare file name. `run.sh` mounts it with
`-v $IMG:/build/initrd.img`, and podman read the bare name as a *named volume*, created an empty
one, and mounted that. Xen reported `MODULE[1]: 0000000090400000 - 0000000090400000 Ramdisk`
(zero bytes) and dom0 panicked at 1.0 s on `Unable to mount root fs`. The guest never started, so
the attempt says nothing about 0003. Relaunched with the absolute path; logs of the bad attempt
kept on fedora1 as `*-run134-EMPTYMOUNT.log`.

## Run 135, test B: 0003 in dom0 [ran it]

dom0 kernel: clean `048308d86` exported with `git archive`, plus only 0003 (`git format-patch -1
79db70fe3a | git apply`: one file, `arch/riscv/xen/enlighten.c`, +32/-1), `xen_defconfig` +
`guest-kernel/dom0.config`. Cross, tuxmake `riscv_gcc-14`: 9m18s wall, exit 0, 7 warnings.
`Image.gz` sha256 prefix `29d628a149fc`; netback, blkback and bridge built in. Copied over
the test host's dom0 kernel image for this run only, then restored (`ee3b68e3` verified).
Same image, Xen and guest as run 134. Wall 296 s.

From the log [read log]:

- The first kernel is our dom0 build (`root@c0da2336a389`) and prints `Xen 4.18 support found`
  at 0.000000. So 0003 finds the node `make_hypervisor_node()` writes.
- dom0 then does what it did in run 134: brings up xl, creates the guest, back-ends attach. The
  guest (the run 134 kernel) prints its own `Xen 4.18 support found`, gets blkfront xvda and eth0
  192.168.128.2, and passes the raw 1 MiB write/read-back on `/dev/xvda`.
- Then `Expanding d1 grant table from 3 to 4 frames` and immediately
  `(XEN) Assertion this_cpu_ptr(per_cpudata) != NULL failed at ./include/xen/rwlock.h:369`.
  `restart-one.sh` stops on it. No SUMMARY line.

That assertion is the known intermittent one on this Xen build, with the same trigger (grant
table expansion during the guest's disk setup) as runs 57 and 59: `2026-09-24-pcpu-ab-series.md`
counts it on 5 of 21 runs with base Xen `08074f7f22ee`, 0 of 21 with the staging `this_cpu_ptr`
+ place_modules build. It is a Xen-side fault in `_percpu_read_unlock`, reached after dom0 had
already detected Xen and served the guest [inference: nothing in 0003 touches grant tables or
per-cpu data; it only changes how `xen_early_init()` decides it is on Xen]. One run cannot show
that 0003 is uninvolved, only that this failure matches a known one seen without it.

Log: `logs/dt/xen-domu-run135-DT-DOM0.log`.

## Run 136, test B again on the staging `this_cpu_ptr` Xen [ran it]

Same dom0 kernel (0003 only, `29d628a149fc`), same guest and image as runs 134/135. Xen swapped
for this run to `xen-bin-pcpu-4307f2165ce4` (build-id `be26eee`: staging `this_cpu_ptr` +
place_modules backport, 0 asserts in 21 runs, the build run 117 used), then restored to
`08074f7f22ee` together with the dom0 kernel (`ee3b68e3`), both verified by sha256. Wall 567 s.

Result: **pass** [read log]. dom0 (`root@c0da2336a389`) prints `Xen 4.18 support found`; the
guest prints its own; grant table expands 1 -> 2 -> 3 -> 4 frames (the step where run 135
died) without an assertion; xvda, eth0 192.168.128.2, `DOCKER_OK`, `K3S_OK` at 255 s guest time,
`SUMMARY: docker=ok k3s=ok disk=ok`.

Log: `logs/dt/xen-domu-run136-DT-DOM0-PCPU.log`.

## Test C: the same guest kernel with no Xen at all [ran it]

The run 134 guest kernel (`79db70fe3a`: 0001 + 0002 + 0003) booted as the only kernel on plain
QEMU `virt`, with no hypervisor: `qemu-system-riscv64 -M virt -cpu rv64 -smp 1 -m 1g -nographic
-bios opensbi-riscv64-generic-fw_dynamic.bin -kernel Image -append "console=ttyS0 panic=-1"
-no-reboot`, run inside the `local/trixie-riscv64` builder image on the laptop (QEMU TCG, 3.4 s wall).

Result: as expected [read log]. Same version string as the built kernel; **no line mentioning
Xen at all**, no BUG, Oops or WARNING; it reaches `Kernel panic - not syncing: VFS: Unable to
mount root fs on unknown-block(0,0)` at 1.77 s, which is the correct end with no root device.
This repeats the no-Xen check 0003's commit message already reports, now with 0001 and 0002
in the same kernel. What this kernel did on the no-Xen path *before* 0003 was not re-run here.

Log: `logs/dt/testC-noxen.log`.

## Must not claim

Hardware; that 0003 is needed or a fix (it replaces an assumption with a check; before it the kernel
assumed Xen, per its commit title); that 0003 passes reliably (one run per case); that run 136 says anything about the per-cpu
assertion (one more clean run on that build, not evidence of a fix).
