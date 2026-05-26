# Local patches to SoarAlto microbench

Upstream: https://github.com/MoatLab/SoarAlto/tree/main/src/microbenchmark

## `-S <N>` flag — configurable seq:pc multiplier

**Why.** Paper §2 hardcodes `op_iter * 26` read loops for the seq thread
so it issues ~26B loads vs ~4B for the pc thread, balancing thread
runtimes on the paper's Optane hardware. The ratio is HW-dependent (a
faster slow tier needs fewer seq iterations to match pc runtime). Made
it a CLI param and changed the default to 46 (it's what works for our machine).

**Files touched.**
- `src/utils.h`  -> added `int seq_mult` to `header_t`
- `src/utils.c`  -> set default `seq_mult = 26`, added `-S` to getopt
- `src/main.c`   -> replaced hardcoded `26` in `bandwidth()` with
                  `header->seq_mult`; dropped the `/* TODO */` comment

**Tuning on machine.** Measure `-R 0.0` and `-R 1.0` runtimes at default
`-S 26`, then set `S = 26 * (t_pchase / t_stream)`.

## `-N <node>` flag. Per-buffer NUMA placement

**Why.** Upstream allocates both buffers via plain `malloc`
(`init_buf_reg_alloc`), so per-buffer NUMA control was impossible.
Required for replicating Figure 1c of the SOAR/ALTO paper, where each
buffer (pchase = "cold-but-latency-bound", seq = "hot-but-bw-bound")
must live on a chosen tier independently.

**Files touched.**
- `src/utils.h`  -> added `int buf_b_numa_node` to `header_t`
- `src/utils.c`  -> default `buf_b_numa_node = 0`, added `-N` to getopt
- `src/main.c`   -> swapped `init_buf_reg_alloc` -> `init_buf`
                  (which uses `numa_alloc_onnode`), `aligned_free` ->
                  `numa_free`

**Flags.**
- `-r <node>` (existing, but previously unused) -> pchase buffer A NUMA node
- `-N <node>` (new)      -> seq    buffer B NUMA node

Both default to node 0. Example placements:

```
./bench -R 0.5 -r 0 -N 0   # All-on-DRAM
./bench -R 0.5 -r 2 -N 0   # Hot-on-DRAM   (pc on Optane, seq on DRAM)
./bench -R 0.5 -r 0 -N 2   # Cold-on-DRAM  (pc on DRAM, seq on Optane)
./bench -R 0.5 -r 2 -N 2   # All-on-Optane (lower bound)
```
