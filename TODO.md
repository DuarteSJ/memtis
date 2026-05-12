# AOL-weighted hotness — pending work

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
