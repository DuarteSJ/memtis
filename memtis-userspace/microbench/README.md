# microbench — AOL K-curve calibration

Calibrates the per-machine constants `a` and `b` used by the SOAR/ALTO
slowdown model:

```
K   = 1 / (a + b/AOL)
S   = P * K
weight = 1 + S
```

The kernel uses `weight` to scale page hotness inside MEMTIS. `a` and `b`
depend only on hardware (CPU + slow-tier pair), so this calibration is
run once per target machine.

## Layout

| path                     | purpose                                          |
|--------------------------|--------------------------------------------------|
| `calibrate.sh`           | entrypoint. Drives bench, fits a, b             |
| `soar-microbench/`       | vendored SoarAlto microbench (pchase + stream)   |
| `soar-microbench/LOCAL_PATCHES.md` | what changed from the original benchmark |
| `results/`               | calibration CSVs (one per machine/run)           |

## Usage

```bash
# build the bench binary once
cd soar-microbench/src && make

# calibrate
./calibrate.sh
# -> writes results/<host>-<date>.csv and prints a, b
```

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
