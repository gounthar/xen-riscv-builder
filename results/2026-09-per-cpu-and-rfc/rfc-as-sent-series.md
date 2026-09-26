# The RFC series as sent: built from the branch, 48 runs overnight (2026-09-25/26)

Tags: [ran it] = measured on fedora1 in this series; [read source]; [read log]; [inference].
QEMU TCG on an x86 host (fedora1) only. Nothing here says anything about riscv hardware.

## Question

The Xen RFC branch published on 09-24 (`gitlab.com/gounthar/xen`
`rfc/domu-experiments-2026-09-25` @ `d425b43c60`) had never been built or run as a whole. Every
earlier run used the dirty base tree plus one change at a time. And the Linux RFC 0003 (detect Xen
from the device tree) had one run per case ([linux-0003-boot.md](linux-0003-boot.md)).

Two questions:

1. Does the branch build as sent, and does that build run the usual workload?
2. Does a guest with 0003 behave like one without it, over many runs rather than one?

## First, what the branch actually changes [read source]

Against the base tree (dev base `18e92d1e25` plus uncommitted changes to `libxl_riscv.c` and `mm.c`, the working form of RFC 0008-0010), which every binary since 09-22 was built from:

- `tools/libs/light/libxl_riscv.c`: identical.
- `xen/arch/riscv/mm.c`: identical code; the RFC drops the "EXPERIMENT" comments and rewords one.
- `xen/arch/riscv/kernel.c`: `place_modules()` backport (RFC 0011).
- `xen/arch/riscv/include/asm/percpu.h`: `this_cpu_ptr()` fix (RFC 0012).

Against the tree behind the 09-24 B binary `4307f2165ce4`
([pcpu-ab-series.md](pcpu-ab-series.md), 0 asserts in 21 runs), the code is **identical**. Only the
stripped comments differ, in `kernel.c` and `mm.c`. So the Xen half of the RFC already had 21
clean runs before tonight, just not from a build of the branch itself. Tonight adds that build, and
numbers for 0003.

RFC patches 0001-0007 sit below both trees (the base tree is at 0007, `18e92d1e25`). Six of them
touch only `automation/` (upstream's CI image and scripts), which this builder does not use, so
tonight does not exercise them. The seventh, 0006 (`tools/xl: default an unspecified domain type to
PVH on RISC-V`), is in both builds, but every guest config here sets `type = "pvh"` explicitly, so
its default path is not exercised either.

## Design

- **Xen and tools** built from `git archive d425b43c60`, with
  the same builder image and Makefile as every earlier run (`builder/cfg-regen`). Cross-compiled on
  the x86 laptop in `local/trixie-riscv64`, CPU from bash `time` inside the container:

  | Build | wall | CPU (user + sys) |
  |---|---|---|
  | Xen hypervisor (`783835cbda89`) | 53.3 s | 1m24s + 21s |
  | Tools + dom0 image G3 | 1m05s | 3m36s + 52s |
  | dom0 image G2 (tools already built) | 35.0 s | 28.6s + 7.2s |

  The branch builds as sent, exit 0.
- **Two dom0 images**, identical except for the guest kernel (checked with `debugfs`: same payload
  `a1e567498b9a`, same `domu.cfg`, `domu-mn.cfg`, `domu2.cfg`, same `libxenlight` and `xl`):
  - **G2** `b53d810ba3cc`: guest `6ca55de83440` = baptleduc `048308d86` + RFC 0001 + 0002, the
    guest of the A/B and A/C series.
  - **G3** `d70d180a5734`: guest `79318495d69f` = the Linux RFC branch
    `github.com/gounthar/linux-xen-riscv` `rfc/domu-guest-2026-09-25` @ `79db70fe3a`, i.e. G2 plus
    0003.
  - Payload and guest configs are the same as `initrd-tools-kdisk.img` (A/C series); G2 differs
    from it only in the Xen tools, now built from the RFC tree.
- **dom0 kernel** unchanged: clean `048308d86` + `dom0.config` (`ee3b68e3`), no 0003.
- **Workload** as in the A/B and A/C series: `DOM0_MEM=1024M`, `WITH_DISK=1 DISK_MB=512
  K3S_DISK=1`, single-node and two-node alternated the same way in both arms, arms interleaved
  (G2 G3 / G3 G2 per pair), 1800 s cap, stop on assertion or panic.
- **Driver** [`run/rfc-series.sh`](../../run/rfc-series.sh), a copy of `ac-series.sh`: every run installs
  the RFC Xen binary and checks its sha256 (it aborts on a mismatch; it never did), and the arm picks
  the image. Every log carries the RFC build's banner date, `Fri Sep 25 20:36:48 UTC 2026` [read log].
- Started 2026-09-25 22:45 Paris, last run ended 08:11 (24 pairs). fedora1 left on `08074f7f22ee`,
  no tmux, no container, no podman volume [ran it, checked 08:15].
- Logs in the release asset: `logs/rfc/rfc-series.log` and
  `logs/rfc/xen-domu-runNNN-RFC-{G2,G3}.log` (runs 202-249, 48 files).

## Result [ran it]

| arm | mode | runs | clean | assert | other failure |
|---|---|---|---|---|---|
| G2 (no 0003) | single domU | 12 | 12 | 0 | 0 |
| G2 (no 0003) | two-node | 12 | 12 | 0 | 0 |
| G3 (Linux RFC, with 0003) | single domU | 12 | 12 | 0 | 0 |
| G3 (Linux RFC, with 0003) | two-node | 12 | 12 | 0 | 0 |
| **total** | | **48** | **48** | **0** | **0** |

"Clean" means the run reached its normal end markers, `SUMMARY ... k3s=ok` on every guest
(once single-node, twice two-node, both nodes each time), and no assertion or panic.

0003 did what it should, in every run [read log]:

- G3 guests printed `Xen 4.18 support found`: once per single-node run, twice per two-node run
  (both guests).
- G2 guests never printed it. That line comes only from 0003's `xen_early_init()` path, and the
  dom0 kernel does not carry 0003.

Every run, in both arms, has exactly one Xen warning, `(XEN) Xen WARN at arch/riscv/setup.c:56`,
with its breakpoint trap. It is a boot-time warning also present on the base binary (A/C run 137),
not something this series introduced.

Run length, from the driver's 20 s polling (so resolution is coarse): single-node 546-586 s,
median 566 s in both arms; two-node 806-966 s, median 846 s (G2) and 827 s (G3). No difference
worth reading into.

## What this supports

- **The Xen RFC branch builds as sent** with this builder, and the build ran 48 of 48 K3s runs
  clean, including 24 two-node runs, with no per-cpu assertion. Together with 09-24's 21 clean
  runs on code-identical Xen, that is 69 clean runs of the RFC's Xen code under this workload.
- **Linux RFC 0003 detects Xen in the guest every time** (24 of 24 G3 runs, 36 guest boots) and
  made no difference to the outcome: 24 of 24 clean against 24 of 24 for the guest without it.
- For review, this closes "was the branch as posted ever built or run as a whole": yes,
  from the branch, not from a working tree.

## What this does not support

- Anything on riscv hardware, other QEMU versions, SMP guests, or other workloads.
- 0003 in **dom0**: only runs 135/136 (one pass on a pcpu Xen). This series kept dom0 clean.
- RFC 0001-0005 and 0007 (automation): not exercised by this builder. 0006's xl default: not
  exercised, the configs set `type` explicitly.
- That the assertion cannot happen with the RFC Xen. 0 in 48 bounds its rate at roughly 6%
  (one-sided 95%, rule of three); with the 09-24 runs, 0 in 69 bounds it at about 4%.
- A larger `dom0_mem`, where `place_modules()` matters (run 51, 3072M). Everything here ran at 1024M.
