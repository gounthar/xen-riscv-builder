# Per-cpu assertion: interleaved A/B series, runs 75-116 (2026-09-23/24)

Tags: [ran it] = measured on fedora1 in this series; [read log]; [inference].
QEMU TCG on an x86 host (fedora1) only. Nothing here says anything about riscv hardware.

## Question

Does staging's riscv `this_cpu_ptr()` remove
`Assertion this_cpu_ptr(per_cpudata) != NULL failed at ./include/xen/rwlock.h:369`?
Exp 6 (runs 60-66, an earlier note not included here) gave 7 of 7 clean runs against 2 of 7
asserts before, which happens by chance about 9.5% of the time. Not proof.

## Design

- **A** = base Xen `08074f7f22ee` (the dev branch as installed on fedora1).
- **B** = exp 6+7 Xen `4307f2165ce4`: A plus staging's `this_cpu_ptr()` and the `place_modules()`
  backport (staging `f6a20eda`). Both are staging code, not fixes of ours.
- Same conditions in both arms: `DOM0_MEM=1024M`, `WITH_DISK=1 DISK_MB=512 K3S_DISK=1`, payload
  image `initrd-tools-kdisk.img`, single-node and two-node (`MULTINODE=1`) alternated the same way
  in both arms, runs interleaved A/B through the night so time and host load are shared.
- Before every run the script copies the arm's binary over the installed Xen and checks its sha256
  against the expected value (it aborts the series on a mismatch; it never did). The Xen banner
  date in each log also differs by arm (A: 2026-09-22 01:35, B: 2026-09-23 13:22) [read log].
- A run stops on `Assertion .* failed` / panic, or at its normal end (`---HOTPLUG-END---`, plus
  the agent log end in two-node mode), capped at 1800 s.
- Script: [`run/ab-series.sh`](../../run/ab-series.sh) (per-run logic copied from
  `run/kdisk-series-pcpu.sh`); summary log `logs/ab/ab-series.log` and per-run logs
  `logs/ab/xen-domu-runNN-AB-{A,B}.log` (42 files) in the release asset (see [README](README.md)).
- Started 2026-09-23 23:26 Paris, finished 2026-09-24 07:03 (21 pairs), fedora1 left on
  `08074f7f22ee` with nothing running [ran it, checked 08:53].

## Result [ran it]

| arm | mode | clean | assert | other failure |
|---|---|---|---|---|
| A 08074f7f22ee | single domU | 10 | 1 | 0 |
| A 08074f7f22ee | two-node | 6 | 4 | 0 |
| **A total** | | **16** | **5** | 0 |
| B 4307f2165ce4 | single domU | 11 | 0 | 0 |
| B 4307f2165ce4 | two-node | 10 | 0 | 0 |
| **B total** | | **21** | **0** | 0 |

The five asserts are runs 77, 85, 106, 109 (two-node) and 88 (single), all the same line,
`(XEN) Assertion this_cpu_ptr(per_cpudata) != NULL failed at ./include/xen/rwlock.h:369`
[read log]. Every clean run reached `K3S_OK` and the end markers. No run in either arm failed any
other way, so none had to be excluded.

Fisher's exact test on [[5, 16], [0, 21]]:

```
python3 -c "from scipy.stats import fisher_exact as f; t=[[5,16],[0,21]]; print(f(t)[1], f(t,alternative='greater')[1])"
0.0478  0.0239
```

Two-sided p = 0.048, one-sided p = 0.024.

## What this supports

- **The assertion reproduces on the base binary under these conditions** (5 of 21, about 1 in 4;
  4 of the 5 in two-node mode), and **did not occur once in 21 runs of B** under the same
  conditions on the same night. Together with exp 6 (7 of 7 clean, a separate, non-interleaved
  session), B has 28 clean runs and no assert.
- The difference is significant at the 5% level, but only just (two-sided 0.048). It is good
  evidence, not overwhelming: one more A/B series of the same size would make it firm.
- **B differs from A by two changes**, so the runs alone do not say which one removes the assert.
  Attributing it to `this_cpu_ptr()` rests on reading the code: the assertion is about the per-cpu
  pointer, the dev branch's riscv `this_cpu_ptr()` offsets by the CPU number where staging uses
  `__per_cpu_offset[]`, and `place_modules()` only matters when dom0's initrd crosses a bank edge,
  which does not happen at `DOM0_MEM=1024M` (one dom0 bank) [read source; inference]. Separating
  them would take one more arm: A plus the `this_cpu_ptr()` change alone.
- Two-node runs carry most of the risk on A (4 of 10 against 1 of 11 single), consistent with more
  PV disk and network I/O [inference; the split is too small to test].

## Must not claim

That this is a fix of ours (both changes are staging's). Anything on hardware. That the rate on A
is "about 1 in 4" in general: it is this payload, this disk size, TCG, this host.
