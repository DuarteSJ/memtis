# test_weights

Smoke test for the MEMTIS Soar-weight path. Registers two equal regions with
different weights via `/dev/memtis`, touches **A 2x** and **B 1x**, and watches
which one lands on the fast tier. Ranking is `weighted_accesses = freq x weight`.

- `test_weights.c` - mmaps A and B (guard page between so they stay separate
  VMAs), registers weights, hammers them.
- `run_test_weights.sh` - sets up the htmm cgroup + sampler, caps the fast node,
  runs the workload, prints per-region page counts.

## Requirements

htmm kernel (`/dev/memtis` present), `htmm_ctl` built, root.

## Build & run

```sh
cc -O2 -o test_weights test_weights.c

sudo -E ./run_test_weights.sh              # B weighted 4x -> B wins fast tier
sudo -E ./run_test_weights.sh --low 1 --high 1   # equal weights -> A wins
```

## Flags

```
-d, --dram-mb <mb>    fast-node cap        (default = --size-mb)
-f, --fast-node <n>   fast node            (default 0)
-S, --slow-node <n>   slow node            (default 2)
-s, --size-mb <mb>    region size          (default 128)
-l, --low <n>         A weight, xneutral   (default 1, fractional ok)
-H, --high <n>        B weight, xneutral   (default 4, fractional ok)
-w, --watch <s>       poll interval        (default 5)
-h, --help
```

Keep `-d` >= ~100MB.

## Env overrides

Any `htmm_setting` value, uppercased. Useful ones:

```sh
HTMM_COOLING_PERIOD=200000   # faster convergence
HTMM_SAMPLE_PERIOD=99        # denser sampling
```
Also `HTMM_CTL`, `TEST`, `MEMTIS_DEV` for paths.

## Output

```
A(2x,low)  N0=196395 N2=852181   B(1x,high)  N0=820858 N2=227720
```
`N<fast>` / `N<slow>` = pages per node, per region. Ctrl-C to stop.
