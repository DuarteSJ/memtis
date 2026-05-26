# Local patches to SoarAlto microbench

Upstream: https://github.com/MoatLab/SoarAlto/tree/main/src/microbenchmark

## `-S <N>` flag — configurable seq:pc multiplier

**Why.** Paper §2 hardcodes `op_iter * 26` read loops for the seq thread
so it issues ~26B loads vs ~4B for the pc thread, balancing thread
runtimes on the paper's Optane hardware. The ratio is HW-dependent (a
faster slow tier needs fewer seq iterations to match pc runtime). Made
it a CLI param.

**Files touched.**
- `src/utils.h`  — added `int seq_mult` to `header_t`
- `src/utils.c`  — set default `seq_mult = 26`, added `-S` to getopt
- `src/main.c`   — replaced hardcoded `26` in `bandwidth()` with
                   `header->seq_mult`; dropped the `/* TODO */` comment

**Effect on calibration.** None for `a`, `b` extraction — pure pchase
(`-R 0.0`) and pure stream (`-R 1.0`) are single-thread workloads.
`seq_mult` only matters for mixed runs (`-R 0.5`), which we don't fit
anyway (BW saturation puts mix off the K-curve hyperbola).

**Tuning on nvram.** Measure `-R 0.0` and `-R 1.0` runtimes at default
`-S 26`, then set `S = 26 * (t_pchase / t_stream)`.
