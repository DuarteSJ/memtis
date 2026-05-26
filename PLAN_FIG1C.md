# Plan — replicate SOAR/ALTO Figure 1c for MEMTIS

## Goal

Reproduce the "hotness ≠ performance" plot (Figure 1c, paper §2.1) on
**this machine** (nvram, Xeon Gold 5218R, DRAM node 0 / Optane node 2),
restricted to the MEMTIS family of systems:

- **Static placements** (no migration): All-on-DRAM, Hot-on-DRAM,
  Cold-on-DRAM, All-on-Optane.
- **Stock MEMTIS** (unmodified upstream): both buffers in tiered setup,
  MEMTIS picks placement via plain access counts.
- **MEMTIS + AOL** (our patch): same but with the AOL-weighted hotness
  signal.

If our AOL patch is doing something useful, stock MEMTIS should land
near "Hot-on-DRAM" (penalizing the latency-bound pchase buffer), while
MEMTIS+AOL should land closer to "Cold-on-DRAM" (favoring it).

## Workload

SoarAlto microbench, mix mode:

```
./bench -R 0.5 -i <N> -A 2048 -B 2048 -S <seq_mult> -r <pc_node> -N <seq_node>
```

- `-A 2048` `-B 2048` — two 2 GB buffers (paper §2.1).
- `-R 0.5` — both threads active (pchase + seq).
- `-S` — seq:pc multiplier, calibrated per machine so each thread
  contributes roughly equally to runtime. On nvram DRAM-only,
  `-S 46` matched runtimes; for **tiered** placements this needs
  re-tuning because seq-on-Optane runs longer than seq-on-DRAM.
- `-r`, `-N` — per-buffer NUMA node. New flag, see
  `memtis-userspace/microbench/soar-microbench/LOCAL_PATCHES.md`.
- `-i N` — outer iteration count, tune so total wall time ≥ ~60 s for
  stable PMU stats.

## Metric

Total wall time per run. Normalize to All-on-DRAM. Y axis = relative
performance = `t_AllDRAM / t_config` (higher = faster).

## Configs (static placements)

| label          | `-r` (pc) | `-N` (seq) | expected     |
|----------------|-----------|------------|--------------|
| All-on-DRAM    | 0         | 0          | 1.0 (baseline) |
| Hot-on-DRAM    | 2         | 0          | BAD (seq is "hot" by count but BW-bound, doesn't gain much; pc loses a lot) |
| Cold-on-DRAM   | 0         | 2          | GOOD (pc is "cold" by count but latency-bound, gains a lot; seq loses less) |
| All-on-Optane  | 2         | 2          | lowest (lower bound) |

## Configs (MEMTIS-managed)

For these we let MEMTIS migrate pages dynamically. Set up a memcg with
DRAM size = enough to fit ONE 2 GB buffer (~2-3 GB), so MEMTIS has to
choose which buffer wins the fast tier:

- **stock MEMTIS**: run with the **upstream MEMTIS kernel** (no AOL patch).
- **MEMTIS + AOL**: run with our `5.15.19-htmm-aol` kernel.

Same userspace command, same memcg config. Only the running kernel
changes.

## Why two separate kernels (instead of a runtime toggle)

Cleanest possible A/B:

- Eliminates risk that some other change we made (PMU encoding,
  per-CPU iteration, etc.) is what shifted results.
- Forces us to confirm our patch even *does anything* before
  investing in a sysfs toggle.

Once the A/B shows our patch matters, we add a runtime mode
(`htmm_mode=4` = AOL) so we can toggle without rebuilds and run the
"weight pinned to `AOL_SCALE`" regression check in Step 3.

## Build plan

### 1. Stock MEMTIS kernel

- Worktree at clean upstream MEMTIS commit (the `92487b973` baseline
  from the summary, or `main` if upstream hasn't moved).
- Build with `EXTRAVERSION = -memtis-stock` so we can `uname -r` to
  distinguish.
- Install via `make modules_install && make install`.

### 2. MEMTIS + AOL kernel

- Already done. `uname -r` -> `5.15.19-htmm-aol`.

### 3. GRUB

- One-shot via `grub-reboot` to switch between them. On a hang,
  IPMI cycle -> falls back to `saved_entry`.

## Run plan

For each kernel × config (8 total runs):

1. Reboot into target kernel (one-shot grub-reboot, verify `uname -r`).
2. Create memcg with DRAM size = ~3 GB (enough for one buffer + some
   slack).
3. Echo the bench PID into the memcg.
4. Run bench, record wall time.
5. Tear down memcg.

Cross-kernel reboots are slow but only need to happen twice (stock,
then AOL) — within a kernel we can iterate all configs without
rebooting.

## Output

CSV of `kernel,config,t_pc_node,t_seq_node,wall_s,norm_perf`.
Plot bar chart matching Figure 1c style.

## Open questions / TODO

- [ ] Re-tune `-S` for the **tiered** mix workload. Numbers from
  single-tier (`-S 46` on DRAM) don't transfer. May need
  `-S` ~ a few hundred when seq is on Optane.
- [ ] Decide memcg DRAM budget. Has to be tight enough that placement
  matters but not so tight that MEMTIS spends all its time migrating.
  Start with ~3 GB and bisect.
- [ ] Confirm stock MEMTIS upstream commit to compare against. Probably
  `92487b973` (the parent of our branch).
- [ ] Wire up cgroup setup. Look at `memtis-userspace/scripts/run_bench.sh`
  for the existing pattern.
- [ ] Build stock kernel — needs the same BTF/pahole workaround we
  applied for our build (`DEBUG_INFO_BTF` off, or
  `PAHOLE_OPT=--skip_encoding_btf_enum64`).

## After Figure 1c works

Then we add a runtime toggle. **Important:** AOL weighting is orthogonal
to `htmm_mode` (which is the migration *policy* enum: NO_MIG, BASELINE,
HUGEPAGE_OPT, HUGEPAGE_OPT_V2). AOL changes how the hotness *input* is
computed, not how migration decisions are made. Should compose with any
mode.

Design: new sysfs file alongside `htmm_mode`:

```
/sys/kernel/mm/htmm/htmm_aol_weighting   0 = off (stock), 1 = on (AOL)
```

- `=0`: pin `aol_weight` to `AOL_SCALE`, skip `update_aol_counters`
  body. Per-page weight = raw access count = stock MEMTIS semantics.
- `=1`: compute `aol_weight` from PMU counters every period. Per-page
  weight = access × aol_weight = our patch.

Validates: with `htmm_aol_weighting=0` we recover stock numbers
(even on the AOL kernel) -> proves the AOL kernel's other deltas
(per-CPU iteration, PMU encodings) don't shift baseline. With `=1` we
recover the AOL-kernel numbers from this exercise. This is exactly
Step 3 of `TODO.md` (weight pinned to `AOL_SCALE`, regression check).

Then onward to Step 4–8 of `TODO.md` (static non-unit weight, dynamic
weight, ground-truth correlation, full tiered run, soak).
