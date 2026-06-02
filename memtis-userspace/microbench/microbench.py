#!/usr/bin/env python3.11
"""
Orchestrator for soar-microbench: runs static + MEMTIS-managed configurations,
writes a fresh CSV per invocation, plots.

Subcommands
-----------
  run     drive bench, write a new CSV (one column per workload, one row per rep)
  plot    render PNGs from one or more CSVs
  revert  flip dax1.0 back to devdax (booking cleanup)

Examples
--------
  sudo python3 microbench.py run static --reps 3
  sudo python3 microbench.py run all --reps 5 --dram-cap 2GB
  sudo python3 microbench.py run memtis dram
  python3 microbench.py plot                   # newest CSV
  python3 microbench.py plot results/run-a.csv results/run-b.csv
  sudo python3 microbench.py revert

CSV format
----------
Wide: header is the list of workloads run (e.g. `dram,hot,cold,opt,memtis`),
each subsequent row is one rep (wall time in seconds per workload).

Run directory
-------------
Each `run` creates a fresh folder under results/, named to encode all
parameters + the timestamp:

  results/<host>-<kernel>-i<iter>-A<buf_a>-B<buf_b>-S<seq_mult>-cap<dram_cap>-<YYYYmmddHHMM>/

Inside the folder:
  <stem>.csv               wide CSV (one column per workload)
  <stem>.walltime.png      bar chart of wall times              (if --plot)
  <stem>.relperf.png       normalized t_dram / t_x              (if --plot)

`plot` accepts either CSV file paths or run-directory paths. Multi-CSV
plots are dropped under results/combined-<YYYYmmddHHMM>/ unless
--out-dir is given.
"""

from __future__ import annotations

import argparse
import csv as csv_mod
import datetime as dt
import os
import platform
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCH = HERE / "soar-microbench" / "src" / "bench"
SCRIPTS = HERE.parent / "scripts"
RESULTS = HERE / "results"
SET_MEMCG = SCRIPTS / "set_htmm_memcg.sh"
SET_MEM_SIZE = SCRIPTS / "set_mem_size.sh"

WORKLOADS = ["dram", "hot", "cold", "opt", "memtis"]
ALIASES = {
    "static": ["dram", "hot", "cold", "opt"],
    "all":    ["dram", "hot", "cold", "opt", "memtis"],
}

# pc_node, seq_node for static placements
STATIC_PLACEMENT = {
    "dram": (0, 0),
    "hot":  (2, 0),
    "cold": (0, 2),
    "opt":  (2, 2),
}

WORKLOAD_LABELS = {
    "dram":   "All on\nDRAM",
    "hot":    "Hot on DRAM\n(pc->Optane,\nseq->DRAM)",
    "cold":   "Cold on DRAM\n(pc->DRAM,\nseq->Optane)",
    "opt":    "All on\nOptane",
    "memtis": "MEMTIS\nmanaged",
}

FILENAME_RE = re.compile(
    r"^(?P<host>[^-]+)-(?P<kernel>.+?)"
    r"-i(?P<iter>\d+)-A(?P<buf_a>\d+)-B(?P<buf_b>\d+)-S(?P<seq_mult>\d+)"
    r"-cap(?P<dram_cap>[^-]+)-(?P<date>\d{12})$"
)


# ---------- helpers ----------

def need_root():
    if os.geteuid() != 0:
        sys.exit("this command must be run as root")


def sh(cmd, **kw):
    kw.setdefault("check", True)
    return subprocess.run(cmd, **kw)


def sh_out(cmd) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def dax_mode() -> str | None:
    try:
        out = sh_out(["daxctl", "list", "-d", "dax1.0"])
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    m = re.search(r'"mode":\s*"([^"]+)"', out)
    return m.group(1) if m else None


def ensure_dax_system_ram():
    mode = dax_mode()
    if mode == "system-ram":
        print("dax1.0 already system-ram")
        return
    print(f"dax1.0 mode = {mode!r}; reconfiguring to system-ram")
    sh(["daxctl", "reconfigure-device", "dax1.0", "--mode=system-ram"])


NUMA_BAL_PATH = Path("/proc/sys/kernel/numa_balancing")


def disable_autonuma() -> str | None:
    """Set numa_balancing=0, return prior value (str) so caller can restore."""
    try:
        prev = NUMA_BAL_PATH.read_text().strip()
    except OSError as e:
        print(f"warn: cannot read numa_balancing: {e}", file=sys.stderr)
        return None
    if prev == "0":
        print("numa_balancing already 0")
        return prev
    print(f"numa_balancing was {prev}; setting 0 for the run")
    NUMA_BAL_PATH.write_text("0")
    return prev


def restore_autonuma(prev: str | None):
    if prev is None or prev == "0":
        return
    try:
        NUMA_BAL_PATH.write_text(prev)
        print(f"numa_balancing restored to {prev}")
    except OSError as e:
        print(f"warn: could not restore numa_balancing to {prev}: {e}",
              file=sys.stderr)


def revert_dax_devdax():
    mode = dax_mode()
    if mode == "devdax":
        print("dax1.0 already devdax")
        return
    print(f"dax1.0 mode = {mode!r}; reverting to devdax")
    sh(["daxctl", "reconfigure-device", "dax1.0", "--mode=devdax", "--force"])


def expand_workloads(items) -> list[str]:
    out = []
    for w in items:
        if w in ALIASES:
            out.extend(ALIASES[w])
        elif w in WORKLOADS:
            out.append(w)
        else:
            sys.exit(f"unknown workload: {w}")
    seen = set()
    return [w for w in out if not (w in seen or seen.add(w))]


# ---------- bench runner ----------

def bench_argv(workload: str, iter_: int, buf_a: int, buf_b: int,
               seq_mult: int) -> list[str]:
    args = [str(BENCH), "-R", "0.5", "-i", str(iter_),
            "-A", str(buf_a), "-B", str(buf_b), "-S", str(seq_mult)]
    if workload != "memtis":
        pc, seqn = STATIC_PLACEMENT[workload]
        args += ["-r", str(pc), "-N", str(seqn)]
    return args


def time_run(argv: list[str]) -> float:
    t0 = time.monotonic()
    subprocess.run(argv, check=True, stdout=subprocess.DEVNULL)
    return time.monotonic() - t0


def setup_memcg(dram_cap: str):
    sh(["bash", str(SET_MEMCG), "htmm", "remove"], stderr=subprocess.DEVNULL,
       check=False)
    sh(["bash", str(SET_MEMCG), "htmm", str(os.getpid()), "enable"])
    sh(["bash", str(SET_MEM_SIZE), "htmm", "0", dram_cap])


def teardown_memcg():
    sh(["bash", str(SET_MEMCG), "htmm", str(os.getpid()), "disable"])
    # move self back to root cgroup so the htmm cgroup is empty -> rmdir succeeds
    try:
        Path("/sys/fs/cgroup/cgroup.procs").write_text(f"{os.getpid()}\n")
    except OSError as e:
        print(f"warn: could not move self to root cgroup: {e}", file=sys.stderr)
    sh(["bash", str(SET_MEMCG), "htmm", "remove"])


# ---------- CSV ----------

def build_run_stem(host: str, kernel: str, args) -> str:
    when = dt.datetime.now().strftime("%Y%m%d%H%M")
    return (f"{host}-{kernel}"
            f"-i{args.iter}-A{args.buf_a}-B{args.buf_b}-S{args.seq_mult}"
            f"-cap{args.dram_cap}-{when}")


def parse_filename(stem: str) -> dict | None:
    m = FILENAME_RE.match(stem)
    return m.groupdict() if m else None


# ---------- subcommands ----------

def cmd_run(args):
    need_root()
    workloads = expand_workloads(args.workloads)

    host = socket.gethostname()
    kernel = platform.release()
    if args.csv:
        csv_path = Path(args.csv)
        run_dir = csv_path.parent
    else:
        stem = build_run_stem(host, kernel, args)
        run_dir = RESULTS / stem
        csv_path = run_dir / f"{stem}.csv"
    run_dir.mkdir(parents=True, exist_ok=True)
    print(f"run dir -> {run_dir}")
    print(f"CSV     -> {csv_path}")

    ensure_dax_system_ram()
    prev_autonuma = disable_autonuma()

    # workload -> list[float], filled in workload-major order
    results: dict[str, list[float]] = {w: [] for w in workloads}

    try:
        for w in workloads:
            if w == "memtis":
                setup_memcg(args.dram_cap)
                time.sleep(2)
            try:
                for rep in range(1, args.reps + 1):
                    argv = bench_argv(w, args.iter, args.buf_a, args.buf_b,
                                      args.seq_mult)
                    t = time_run(argv)
                    results[w].append(t)
                    print(f"  {w} rep {rep}/{args.reps}: {t:.3f} s")
                    # flush partial CSV every rep to survive crashes
                    write_csv(csv_path, workloads, results, args.reps)
            finally:
                if w == "memtis":
                    teardown_memcg()
                    time.sleep(1)
    finally:
        restore_autonuma(prev_autonuma)

    print(f"\ndone -> {csv_path}")
    if args.plot:
        plot_csvs([csv_path], Path(args.out_dir) if args.out_dir else run_dir,
                  show=False)


def write_csv(path: Path, workloads: list[str],
              results: dict[str, list[float]], reps: int):
    """Wide CSV: one column per workload, one row per rep. Missing cells blank."""
    with path.open("w", newline="") as f:
        w = csv_mod.writer(f)
        w.writerow(workloads)
        for rep in range(reps):
            row = []
            for wk in workloads:
                if rep < len(results[wk]):
                    row.append(f"{results[wk][rep]:.6f}")
                else:
                    row.append("")
            # skip all-empty rows (nothing measured yet for this rep)
            if any(c != "" for c in row):
                w.writerow(row)


def cmd_plot(args):
    if args.csv:
        csvs = [resolve_csv(Path(p)) for p in args.csv]
    else:
        csvs = [newest_csv(RESULTS)]
    if args.out_dir:
        out_dir = Path(args.out_dir)
    elif len(csvs) == 1:
        # single CSV -> drop PNGs next to it (its run dir)
        out_dir = csvs[0].parent
    else:
        # multi-CSV combined plot -> put under results/combined-<date>/
        out_dir = RESULTS / f"combined-{dt.datetime.now():%Y%m%d%H%M}"
    plot_csvs(csvs, out_dir, show=args.show)


def resolve_csv(p: Path) -> Path:
    """Accept either a CSV file or a run directory containing one."""
    if p.is_dir():
        cands = list(p.glob("*.csv"))
        if not cands:
            sys.exit(f"no CSV in {p}")
        if len(cands) > 1:
            sys.exit(f"multiple CSVs in {p}; pass an explicit one")
        return cands[0]
    return p


def cmd_revert(args):
    need_root()
    revert_dax_devdax()


def newest_csv(d: Path) -> Path:
    csvs = sorted(d.rglob("*.csv"), key=lambda p: p.stat().st_mtime)
    if not csvs:
        sys.exit(f"no CSV under {d}")
    return csvs[-1]


# ---------- plotting ----------

def plot_csvs(csv_paths: list[Path], out_dir: Path, show=False):
    import pandas as pd
    import matplotlib.pyplot as plt

    rows = []        # long-format median+min+max per (group_label, workload)
    for csv_path in csv_paths:
        meta = parse_filename(csv_path.stem) or {}
        label = meta.get("kernel", csv_path.stem)
        cap = meta.get("dram_cap")
        if cap:
            label += f" (cap {cap})"
        df = pd.read_csv(csv_path)
        for wk in df.columns:
            col = pd.to_numeric(df[wk], errors="coerce").dropna()
            if col.empty:
                continue
            rows.append({
                "label": label, "workload": wk,
                "median": col.median(),
                "min": col.min(), "max": col.max(),
                "n": len(col),
            })
    if not rows:
        sys.exit("no numeric data found in CSVs")
    agg = pd.DataFrame(rows)

    # relative perf = t_dram / t_x, computed within each label
    rel = []
    for label, sub in agg.groupby("label"):
        base = sub[sub.workload == "dram"]
        if base.empty:
            continue
        b = base.iloc[0]["median"]
        sub = sub.assign(rel_perf=b / sub["median"])
        rel.append(sub)
    agg_rel = (pd.concat(rel) if rel else agg)

    out_dir.mkdir(parents=True, exist_ok=True)
    out_stem = (csv_paths[0].stem if len(csv_paths) == 1
                else f"combined-{dt.datetime.now():%Y%m%d%H%M}")

    _bar(agg, "median", "wall time (s)",
         f"soar-microbench wall time — {out_stem}",
         out_dir / f"{out_stem}.walltime.png",
         err_lo="min", err_hi="max")
    if "rel_perf" in agg_rel.columns:
        _bar(agg_rel, "rel_perf", "relative perf (t_dram / t_x)",
             f"normalized perf vs All-DRAM — {out_stem}",
             out_dir / f"{out_stem}.relperf.png")
    if show:
        plt.show()


def _bar(agg, value_col, ylabel, title, out_path,
         err_lo: str | None = None, err_hi: str | None = None):
    import matplotlib.pyplot as plt
    labels = sorted(agg["label"].unique())
    workloads = [w for w in WORKLOADS if w in agg["workload"].unique()]
    x = list(range(len(workloads)))
    width = 0.8 / max(len(labels), 1)

    fig, ax = plt.subplots(figsize=(max(7, 1.5 * len(workloads)), 5))
    for i, lab in enumerate(labels):
        sub = agg[agg.label == lab].set_index("workload")
        vals = [sub.loc[w, value_col] if w in sub.index else 0 for w in workloads]
        if err_lo and err_hi:
            lows  = [vals[j] - sub.loc[w, err_lo] if w in sub.index else 0
                     for j, w in enumerate(workloads)]
            highs = [sub.loc[w, err_hi] - vals[j] if w in sub.index else 0
                     for j, w in enumerate(workloads)]
            yerr = [lows, highs]
        else:
            yerr = None
        offset = (i - (len(labels) - 1) / 2) * width
        bars = ax.bar([xi + offset for xi in x], vals, width, label=lab,
                      yerr=yerr, capsize=2)
        for b, v in zip(bars, vals):
            if v > 0:
                ax.annotate(f"{v:.2f}", (b.get_x() + b.get_width() / 2, v),
                            ha="center", va="bottom", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels([WORKLOAD_LABELS.get(w, w) for w in workloads])
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(loc="best", fontsize=8)
    ax.grid(axis="y", linestyle=":", alpha=0.5)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    print(f"wrote {out_path}")


# ---------- main ----------

def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("run", help="execute workloads, write a fresh CSV")
    pr.add_argument("workloads", nargs="+",
                    help=f"any of {WORKLOADS + list(ALIASES)}")
    pr.add_argument("--reps", type=int, default=1)
    pr.add_argument("--iter", type=int, default=5)
    pr.add_argument("--buf-a", type=int, default=2048, help="MB")
    pr.add_argument("--buf-b", type=int, default=2048, help="MB")
    pr.add_argument("--seq-mult", type=int, default=46)
    pr.add_argument("--dram-cap", default="2GB",
                    help="cgroup DRAM cap for memtis runs")
    pr.add_argument("--csv", help="CSV path (default encodes params + date)")
    pr.add_argument("--plot", action="store_true", help="plot after the run")
    pr.add_argument("--out-dir", help="plot output dir")
    pr.set_defaults(func=cmd_run)

    pp = sub.add_parser("plot", help="render PNGs from CSVs")
    pp.add_argument("csv", nargs="*", help="(default: newest under results/)")
    pp.add_argument("--out-dir")
    pp.add_argument("--show", action="store_true")
    pp.set_defaults(func=cmd_plot)

    pv = sub.add_parser("revert", help="dax1.0 back to devdax")
    pv.set_defaults(func=cmd_revert)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
