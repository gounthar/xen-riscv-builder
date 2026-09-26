# Xen riscv64 domU: per-cpu assertion series and the RFC series as posted (2026-09-23 to 09-26)

Everything here ran under QEMU TCG (`qemu-system-riscv64`, virt, AIA) on one x86_64 host.
Nothing here says anything about riscv64 hardware.

The RFC branches these results are about:

- Xen: `gitlab.com/gounthar/xen`, branch `rfc/domu-experiments-2026-09-25` @ `d425b43c60`
  (12 patches on the dev base `8bc1c241d4`).
- Linux guest: `github.com/gounthar/linux-xen-riscv`, branch `rfc/domu-guest-2026-09-25` @
  `79db70fe3a` (3 patches on baptleduc `048308d86`).

## Results

| Write-up | Question | Result |
|---|---|---|
| [pcpu-ab-series.md](pcpu-ab-series.md) | Does staging's `this_cpu_ptr()` + the `place_modules()` backport remove `Assertion this_cpu_ptr(per_cpudata) != NULL failed at ./include/xen/rwlock.h:369`? | base 5 of 21 asserts, patched 0 of 21 (Fisher p = 0.048); the two changes not separated |
| [pcpu-only-series.md](pcpu-only-series.md) | Does the `this_cpu_ptr()` change (RFC 0012) alone remove it? | base 12 of 29, RFC 0012 alone 0 of 29 (p = 0.00012) |
| [linux-0003-boot.md](linux-0003-boot.md) | Does Linux RFC 0003 (detect Xen from the device tree) find Xen as domU and as dom0? | yes both ways, quiet without Xen; one run per case |
| [rfc-as-sent-series.md](rfc-as-sent-series.md) | Does the Xen RFC branch build as posted, and does 0003 hold up over many runs? | builds; 48 of 48 clean, 24 with 0003 in the guest, 24 without |

The workload in the three series is the same (the 0003 boot tests used single runs): a K3s node (or two) in riscv64 PVH domUs with its state
on a PV disk, PV networking over a dom0 bridge, `dom0_mem=1024M`, runs interleaved between arms.
The drivers are in [`run/`](../../run/): `ab-series.sh`, `ac-series.sh` and `rfc-series.sh`,
with per-run logic from `run/kdisk-series-pcpu.sh`. Each run calls `$HOME/xen-run/run.sh`, which is
[`run/run-podman.sh`](../../run/run-podman.sh) as it ran (podman + the builder image, `make go`),
and that pipes [`run/xen-run2.sh`](../../run/xen-run2.sh) into dom0's console. They assume the
layout of the test host (`$HOME/xen-run`) and are not portable as they stand.

The `this_cpu_ptr()` and `place_modules()` changes are Oleksii Kurochko's, from upstream staging
(f75780d26b, f6a20eda92). The RFC carries them to the dev branch; they are not findings of ours.

## Logs

Raw serial logs of every run (Xen, dom0 and guest consoles on one stream), attached to the GitHub
release `results-2026-09-26` of this repository as `xen-riscv-results-2026-09-logs.tar.xz`:

| Directory | Runs | Files |
|---|---|---|
| `logs/ab/` | 75-116 | 42 run logs + `ab-series.log` |
| `logs/ac/` | 137-194 | 58 run logs + `ac-series.log` |
| `logs/dt/` | 134-136, test C | 4 |
| `logs/rfc/` | 202-249 | 48 run logs + `rfc-series.log` |

Each `*-series.log` has one line per run: arm, mode, installed Xen sha256, start, wall time, stop
reason, and counts of assertions, panics and K3s success markers.
