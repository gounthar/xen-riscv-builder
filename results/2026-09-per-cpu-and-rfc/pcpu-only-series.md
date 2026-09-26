# Per-cpu assertion: RFC 0012 alone, interleaved A/C series, runs 137-194 (2026-09-25)

Tags: [ran it] = measured on fedora1 in this series; [read log]; [read source]; [inference].
QEMU TCG on an x86 host (fedora1) only. Nothing here says anything about riscv hardware.

## Question

Does RFC 0012 (`xen/riscv: make this_cpu_ptr() add the per-cpu offset`, d425b43c60) remove
`Assertion this_cpu_ptr(per_cpudata) != NULL failed at ./include/xen/rwlock.h:369` **on its own**?

The 09-24 series ([pcpu-ab-series.md](pcpu-ab-series.md)) compared base against base plus two
changes, staging's `this_cpu_ptr()` and the `place_modules()` backport, and could not separate
them. `place_modules()` alone (530f466eeebe) had already hit the assertion once (run 59) [read log],
so the untested arm was `this_cpu_ptr()` alone. That is what the RFC cover note warned about when
it said to run 0012 together with 0011.

## Design

- **A** = base Xen `08074f7f22ee`, the same binary as arm A on 09-24.
- **C** = base plus only the `xen/arch/riscv/include/asm/percpu.h` hunk of RFC 0012, binary
  `fd4a2057216b`. No `place_modules()` change.
  - Built from a copy of the base tree (dev base `18e92d1e25` plus uncommitted changes to `libxl_riscv.c` and `mm.c`, the working form of RFC 0008-0010),
    with the hunk applied by `git apply`. The hunk is byte-identical to the one in `xen-pcpu`
    (same blob `b8bdfef724`) [ran it].
  - Control that the tree matches the base binary: reverting the hunk and rebuilding gives a
    657104-byte image that differs from `08074f7f22ee` in 46 bytes, which are the build timestamp
    string [ran it]. The C image is 653008 bytes.
  - Build: Xen only, cross-compiled in `local/trixie-riscv64` on the x86 laptop, 38.8 s wall.
    CPU time not captured (`time` measured the docker client only).
- Conditions identical to 09-24: `DOM0_MEM=1024M`, `WITH_DISK=1 DISK_MB=512 K3S_DISK=1`, payload
  `initrd-tools-kdisk.img`, single-node and two-node alternated the same way in both arms, arms
  interleaved (A B / B A alternating per pair) so time and host load are shared.
- Driver [`run/ac-series.sh`](../../run/ac-series.sh): a copy of `ab-series.sh` with only arm B's binary and sha, the
  output log name and the start/done labels changed (diff checked before starting). It installs the
  arm's binary before every run and aborts on a sha256 mismatch; it never did. Xen banner dates
  differ by arm in every log (A: 2026-09-22 01:35:30, C: 2026-09-25 07:51:33) [read log].
- Logs in the release asset: `logs/ac/ac-series.log` and per-run logs
  `logs/ac/xen-domu-runNNN-AC-{A,C}.log` (58 files). In `ac-series.log` arm C is still labelled
  `arm=B`, because the script was copied from the A/B one.
- Started 2026-09-25 09:53 Paris, last run ended 20:02 (29 pairs; the script stops starting pairs
  that cannot finish by the 20:30 cutoff). fedora1 left on `08074f7f22ee`, no tmux, no container,
  no podman volume [ran it, checked 20:03].

## Result [ran it]

| arm | mode | clean | assert | other failure |
|---|---|---|---|---|
| A 08074f7f22ee | single domU | 11 | 4 | 0 |
| A 08074f7f22ee | two-node | 6 | 8 | 0 |
| **A total** | | **17** | **12** | 0 |
| C fd4a2057216b | single domU | 15 | 0 | 0 |
| C fd4a2057216b | two-node | 14 | 0 | 0 |
| **C total** | | **29** | **0** | 0 |

The twelve asserts are runs 144, 147, 168, 171, 174, 176, 177, 179, 184, 185, 190 and 192, all the
same line, `(XEN) Assertion this_cpu_ptr(per_cpudata) != NULL failed at ./include/xen/rwlock.h:369`
[read log]. Every clean run in both arms reached `K3S_OK` and the end markers. No run failed in any
other way, so none was excluded.

C reached the triggering point: all 29 C logs show a guest grant table growing from 2 to 3 (or 3 to
4) frames. In A, the six logs without that line (147, 174, 176, 179, 184, 192) are all assert runs
that died earlier, right after the 1 to 2 expansion [read log].

Fisher's exact test (scipy `fisher_exact`):

| table [[A assert, A clean], [C assert, C clean]] | two-sided | one-sided |
|---|---|---|
| all runs [[12, 17], [0, 29]] | 0.00012 | 0.00006 |
| two-node only [[8, 6], [0, 14]] | 0.0019 | 0.00097 |
| single-node only [[4, 11], [0, 15]] | 0.10 | 0.050 |

## What this supports

- **Under these conditions, the `percpu.h` hunk of RFC 0012 is enough on its own to stop the
  assertion from appearing**: 0 of 29 against 12 of 29 on the base binary, interleaved, same host,
  same day. `place_modules()` is not needed for that. Together with run 59 (`place_modules()`
  alone still asserted), the 09-24 result can now be credited to `this_cpu_ptr()`.
- The A rate is higher than on 09-24 (12/29 = 41% against 5/21 = 24%). I do not know why. Both
  series used the same binary, image and settings; day against night host load is the obvious
  difference, and nothing here tests it.
- As on 09-24, two-node mode reproduces the assertion much more often than single-node.

## What this does not support

- That RFC 0012 is *the* fix, or that the assertion cannot happen with it. Zero in 29 bounds the
  C rate at roughly 10% (one-sided 95%, rule of three), not at zero.
- Anything about riscv hardware, other QEMU versions, SMP guests, or other workloads.
- The mechanism. RFC 0012's commit message explains why the old macro is wrong (it adds the CPU
  number in bytes instead of `__per_cpu_offset[cpu]`) [read source]. Why that turns into a NULL
  `per_cpudata` under grant-table growth has not been traced.
- The change itself is Oleksii's (staging f75780d26b moved `this_cpu_ptr()` to common code with
  the offset); RFC 0012 carries it to the dev branch. It is not our finding.

## Consequence for the RFC series

The note "always run 0012 with 0011" can be relaxed for the assertion: on this bench 0012 alone is
enough. Whether 0011 is still needed for larger `dom0_mem` is a separate question, and this series
does not touch it (it ran at `DOM0_MEM=1024M`, where base boots without `place_modules()`).
