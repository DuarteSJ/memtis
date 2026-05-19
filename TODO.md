asdfasdf# AOL-weighted hotness — pending work

- [ ] **Verify scale-invariant sites are actually invariant.** Review-only
  pass — no code changes expected. The `get_idx` descale handles every
  reader for free, but worth a mental check:
  - All `get_idx(weighted_accesses)` readers (descale happens inside
    `get_idx`): `linux/mm/rmap.c`, `linux/mm/huge_memory.c`,
    `linux/mm/htmm_core.c`.
  - All `weighted_accesses >>= 1` cooling halves.
  - All pginfo-to-pginfo copies (`copy_transhuge_pginfo`, the split path in
    `linux/mm/huge_memory.c`, the migration copies in `htmm_core.c`).

- [ ] **Sanity-check `skewness` accumulation overflow.**
  `skewness += weighted_accesses²` runs in a `u64` accumulator over up to
  512 subpages. With `weighted_accesses` capped at `U32_MAX`, one
  near-saturated subpage contributes up to ~1.8e19 — a *single* such
  subpage already consumes most of `u64`'s headroom. The
  `meta_page->idx >= 13` short-circuit before the skewness branch
  (`check_transhuge_cooling`) is what prevents this in practice. Confirm
  on a representative workload that pages reaching the squared-overflow
  regime are always caught by that filter; if not, clamp the per-subpage
  contribution before squaring.

## Empirical validation

- [ ] Dump per-memcg access histograms (`hotness_hg`, `ebp_hotness_hg`) on
  a representative workload, before and after the AOL-weighting changes.
  Confirm the distribution shape is preserved and the active/warm
  thresholds re-converge.
- [ ] Watch `pginfo_t.weighted_accesses` saturation rates in practice. If
  too many pages pin at `U32_MAX`, drop `AOL_SHIFT` from 10 → 6 (gains
  ~4 bits of integer headroom at the cost of weight resolution, still
  well below PMU noise).

## Lower priority

- [ ] Tune `AOL_PARAM_A` / `AOL_PARAM_B` (`linux/mm/htmm_core.c:23-24`)
  using the microbenchmark described in the SOAR/ALTO paper.
- [ ] Scale PMU counter reads by `time_enabled` / `time_running` in
  `aol_read_and_update` (`linux/mm/htmm_sampler.c`). Currently raw deltas
  are used.
- [ ] Re-read `aol_weight` per-sample inside `ksamplingd` instead of once
  at thread start (`linux/mm/htmm_sampler.c`), so updates that happen
  during the loop take effect. Tradeoff: per-sample atomic read overhead
  vs. accuracy.




Design shi:

Add bins vs shift and keep bins



## Test plan (incremental)

- [ ] **Step 0 — verify PMU event encodings.** On target box:
  `perf stat -e r060006a3,r01b0,r4301b1,r4101b1,r003c -a sleep 5` vs
  symbolic names. Numbers must match. Confirm no OFFCORE_RSP `config1`
  required for the ORO events on this uarch.
- [ ] **Step 1 — counter sanity, userspace only.** Pointer-chase > LLC and
  STREAM at varying thread counts. Compute weight by hand from `perf stat`
  deltas. Expect `1.0` idle, `2–5×` saturated.
- [ ] **Step 2 — kernel readback only.** `printk` `a1,a3,s_llc,c,aol,p,k,s,weight`
  per period under dummy load. Must agree with Step 1. Check
  `time_enabled vs time_running` — if `<1`, fix scaling before continuing.
- [ ] **Step 3 — weighted path, weight pinned to `AOL_SCALE`.** Run a MEMTIS
  workload; `hotness_hg`, promo/demo counts must be ~identical to baseline
  `92487b973`. If not, bisect fixed-point sites (`get_idx`, seeds,
  `sat_add_u32`, skewness descale).
- [ ] **Step 4 — static non-unit weight (2×, 4×).** Distribution shifts
  uniformly, thresholds re-converge after cooling cycles. Add a counter
  for `sat_add_u32` saturations; if >1 % of pages pin `U32_MAX` at 4×,
  drop `AOL_SHIFT` 10 → 6.
- [ ] **Step 5 — dynamic weight, hardcoded `a=6, b=750`.** DRAM-only run.
  Log `aol_weight` time series with workload phase markers; weight tracks
  load.
- [ ] **Step 6 — correlate with ground truth.** Partial-window runs
  (partest-style). Measure real solo-vs-shared slowdown. Plot
  `weight - 1` vs measured slowdown. Pearson > ~0.7 = model works;
  otherwise refit `a, b`. Compare correlation strength against SOAR's
  reported numbers.
- [ ] **Step 7 — tiered run, full pipeline.** DRAM + NVM/CXL on real
  workloads (GAP-bc, XSBench, …). A/B weight=1 vs weight=dynamic.
  Metrics: promotion volume, hit ratio, runtime, P99 latency. Win =
  lower runtime under contention, no regression at low load.
- [ ] **Step 8 — soak.** 24 h under varying load. Watch saturation drift,
  counter overflow, ksamplingd CPU use (`perf record` on the kthread).

### Quick wins before Step 2
- [ ] Debugfs/sysfs file exposing live `aol_weight` + raw `a1,a3,s_llc,c`
  deltas (saves a rebuild per tuning iteration).
- [ ] Counter for `sat_add_u32` saturation events.
- [ ] Force one `aol_read_and_update()` before the ksamplingd main loop
  so the first ~1 s isn't biased by the `AOL_SCALE` seed.
