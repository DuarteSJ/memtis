# microbench — AOL K-curve calibration + MEMTIS A/B experiments

Two distinct uses:

1. **Calibrate** the per-machine constants `a`, `b` for the SOAR/ALTO
   slowdown model (one-shot, per machine).
2. **Experiment** — run static and MEMTIS-managed placements of the
   soar-microbench mix workload, log timings to CSV, plot results.
   Used to replicate SOAR Figure 1c and to A/B stock MEMTIS vs the
   AOL-weighted variant.

The slowdown model the calibration feeds:

```
K      = 1 / (a + b/AOL)
S      = P * K
weight = 1 + S
```

The kernel uses `weight` to scale page hotness inside MEMTIS. `a` and `b`
depend only on hardware (CPU + slow-tier pair).

## Layout

| path                     | purpose                                          |
|--------------------------|--------------------------------------------------|
| `calibrate.sh`           | calibration entrypoint. Drives bench, fits a, b |
| `configure_memtis.sh`    | one-shot: htmm sysfs tunables + THP + numa_balancing off |
| `microbench.py`          | orchestrator: run static + MEMTIS-managed workloads, append CSV, plot |
| `soar-microbench/`       | vendored SoarAlto microbench (pchase + stream)   |
| `soar-microbench/LOCAL_PATCHES.md` | what changed from the original benchmark |
| `results/`               | CSVs + PNGs                                      |

## Usage — calibration

```bash
# build the bench binary once
cd soar-microbench/src && make

# calibrate
./calibrate.sh
# -> writes results/<host>-<date>.csv and prints a, b
```

## Usage — experiments

Prereqs:
- bench binary built (`make -C soar-microbench/src`).
- DRAM as NUMA node 0; slow tier (Optane) as NUMA node 2.
- htmm sysfs alive (running an htmm/MEMTIS kernel).
- Once per session: `sudo ./configure_memtis.sh` (htmm tunables, THP=always,
  disables auto-NUMA balancing).

Run:

```bash
# static placement bars, 3 reps each
sudo ./microbench.py run static --reps 3

# MEMTIS-managed bar with 2 GB DRAM cap, 5 reps
sudo ./microbench.py run memtis --reps 5 --dram-cap 2GB

# everything (4 static + memtis), 3 reps, plot at end
sudo ./microbench.py run all --reps 3 --plot

# arbitrary subset
sudo ./microbench.py run dram cold memtis --reps 2

# plot only (from existing CSV)
./microbench.py plot                        # newest under results/
./microbench.py plot results/foo.csv --show

# end-of-session: dax1.0 back to devdax
sudo ./microbench.py revert
```

Workloads:

| name    | meaning                                                       |
|---------|---------------------------------------------------------------|
| `dram`  | pchase + seq both on DRAM (baseline)                          |
| `hot`   | pchase on Optane, seq on DRAM ("hot-count" buffer fast tier)  |
| `cold`  | pchase on DRAM, seq on Optane ("cold-count" buffer fast tier) |
| `opt`   | both on Optane (lower bound)                                  |
| `memtis`| both buffers unbound, cgroup caps node-0 DRAM, MEMTIS decides |
| `static`| alias: `dram hot cold opt`                                    |
| `all`   | alias: `dram hot cold opt memtis`                             |

CSV: `results/<host>-<kernel>.csv`. One row per rep; kernel column lets
you mix stock vs AOL runs in one file. Override path with `--csv PATH`.

Tunables (`run` flags): `--reps`, `--iter`, `--buf-a`, `--buf-b`,
`--seq-mult`, `--dram-cap`. Defaults match the calibration setup
(`-i 5 -A 2048 -B 2048 -S 46`, cap `3GB`).

Plots: two PNGs per CSV under `results/`:
- `<stem>.walltime.png` — raw seconds.
- `<stem>.relperf.png`  — `t_dram / t_x`, SOAR Fig 1c style.

## Tunables (env vars for `calibrate.sh`)

| var      | default                          | meaning                          |
|----------|----------------------------------|----------------------------------|
| `BENCH`  | `./soar-microbench/.../bench`    | path to bench binary             |
| `FAST`   | `0`                              | fast NUMA node (local DRAM)      |
| `SLOW`   | `2`                              | slow NUMA node (Optane/CXL)      |
| `DUR`    | `15`                             | target seconds per workload      |
| `BUF_A`  | `2048`                           | pchase buffer MB (paper §2.1)    |
| `BUF_B`  | `2048`                           | seq buffer MB (paper §2.1)       |
| `OUT`    | `results/<host>-<date>.csv`      | output CSV                       |

## Method (brief)

For each workload (`pchase` = pure pointer-chase, `stream` = pure
sequential read):

1. Pilot on FAST tier with `-i 1` -> measure wall time.
2. Pick `-i` ≈ `DUR / t_pilot` so each run lasts ~`DUR` seconds.
3. Run on FAST tier with `perf stat` -> A1, A3, s_LLC, c, t_fast.
4. Run on SLOW tier -> t_slow.
5. Compute `AOL = A1/A3`, `P = s_LLC/c`, `S = t_slow/t_fast - 1`,
   `K = S/P`.

Two `(AOL, K)` pairs -> linearize `1/K = a + b·(1/AOL)` -> two equations,
two unknowns, exact solve. (Code uses OLS so adding more workloads
works without changes.)

PMU events (`r010001b1,r000001b0,r060006a3,r0000003c`):
- `r010001b1` = ORO.CYCLES_WITH_DEMAND_DATA_RD        (A1)
- `r000001b0` = OFFCORE_REQUESTS.DEMAND_DATA_RD       (A3)
- `r060006a3` = CYCLE_ACTIVITY.STALLS_L3_MISS         (s_LLC)
- `r0000003c` = CPU_CLK_UNHALTED.THREAD               (c)

## Plugging values into the kernel

Edit `linux/mm/htmm_core.c`:

```c
#define AOL_PARAM_A_SCALED <a * 1024 rounded>
#define AOL_PARAM_B_SCALED <b * 1024 rounded>
```

Both are stored fixed-point in `AOL_SCALE = 1024`. The `calibrate.sh`
output already prints these rounded values.

## Current nvram values

`a = 0.0625, b = 1.28` -> `A_SCALED=64, B_SCALED=1311`.
See `results/` for raw measurements.
