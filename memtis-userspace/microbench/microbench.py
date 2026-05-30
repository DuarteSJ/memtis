#!/usr/bin/env python3
"""
Orchestrator for soar-microbench: runs static + MEMTIS-managed configurations,
appends timings to CSV, plots.

Subcommands
-----------
  run     drive bench, append CSV rows
  plot    render PNGs from a CSV
  revert  flip dax1.0 back to devdax (booking cleanup)

Examples
--------
  sudo python3 microbench.py run static --reps 3
  sudo python3 microbench.py run all --reps 5 --dram-cap 2GB
  sudo python3 microbench.py run memtis dram
  python3 microbench.py plot                   # newest CSV
  python3 microbench.py plot results/foo.csv
  sudo python3 microbench.py revert

CSV columns
-----------
  timestamp, kernel, workload, rep, iter, buf_a_mb, buf_b_mb,
  seq_mult, dram_cap, pc_node, seq_node, walltime_s
"""

from __future__ import annotations

import argparse
import csv as csv_mod
import datetime as dt
import os
import platform
import re
import shutil
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


# ---------- helpers ----------

def need_root():
    if os.geteuid() != 0:
        sys.exit("this command must be run as root")


def sh(cmd, **kw):
    """Run a command; raise on non-zero. Inherits stdout/stderr by default."""
    return subprocess.run(cmd, check=True, **kw)


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
    # de-dup but keep order
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
       check=False)  # best-effort
    sh(["bash", str(SET_MEMCG), "htmm", str(os.getpid()), "enable"])
    sh(["bash", str(SET_MEM_SIZE), "htmm", "0", dram_cap])


def teardown_memcg():
    sh(["bash", str(SET_MEMCG), "htmm", str(os.getpid()), "disable"])
    sh(["bash", str(SET_MEMCG), "htmm", "remove"])


# ---------- CSV ----------

CSV_HEADER = [
    "timestamp", "kernel", "workload", "rep", "iter",
    "buf_a_mb", "buf_b_mb", "seq_mult", "dram_cap",
    "pc_node", "seq_node", "walltime_s",
]


def append_row(csv_path: Path, row: dict):
    new = not csv_path.exists()
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("a", newline="") as f:
        w = csv_mod.DictWriter(f, fieldnames=CSV_HEADER)
        if new:
            w.writeheader()
        w.writerow(row)


# ---------- subcommands ----------

def cmd_run(args):
    need_root()
    workloads = expand_workloads(args.workloads)

    csv_path = (Path(args.csv) if args.csv
                else RESULTS / f"{socket.gethostname()}-{platform.release()}.csv")
    print(f"CSV -> {csv_path}")

    ensure_dax_system_ram()

    kernel = platform.release()
    for w in workloads:
        if w == "memtis":
            setup_memcg(args.dram_cap)
            time.sleep(2)
        try:
            for rep in range(1, args.reps + 1):
                argv = bench_argv(w, args.iter, args.buf_a, args.buf_b,
                                  args.seq_mult)
                t = time_run(argv)
                pc, seqn = (-1, -1) if w == "memtis" else STATIC_PLACEMENT[w]
                cap = args.dram_cap if w == "memtis" else "-"
                row = {
                    "timestamp": dt.datetime.now().isoformat(timespec="seconds"),
                    "kernel": kernel, "workload": w, "rep": rep,
                    "iter": args.iter, "buf_a_mb": args.buf_a,
                    "buf_b_mb": args.buf_b, "seq_mult": args.seq_mult,
                    "dram_cap": cap, "pc_node": pc, "seq_node": seqn,
                    "walltime_s": f"{t:.6f}",
                }
                append_row(csv_path, row)
                print(f"  {w} rep {rep}/{args.reps}: {t:.3f} s")
        finally:
            if w == "memtis":
                teardown_memcg()
                time.sleep(1)

    print(f"\ndone. rows appended to {csv_path}")
    if args.plot:
        plot_csv(csv_path, args.out_dir or RESULTS, show=False)


def cmd_plot(args):
    csv_path = Path(args.csv) if args.csv else newest_csv(RESULTS)
    out_dir = Path(args.out_dir) if args.out_dir else RESULTS
    plot_csv(csv_path, out_dir, show=args.show)


def cmd_revert(args):
    need_root()
    revert_dax_devdax()


def newest_csv(d: Path) -> Path:
    csvs = sorted(d.glob("*.csv"), key=lambda p: p.stat().st_mtime)
    if not csvs:
        sys.exit(f"no CSV under {d}")
    return csvs[-1]


# ---------- plotting ----------

def plot_csv(csv_path: Path, out_dir: Path, show=False):
    import pandas as pd
    import matplotlib.pyplot as plt

    df = pd.read_csv(csv_path)
    df = df[df["walltime_s"].notna() & (df["walltime_s"] > 0)]
    if df.empty:
        sys.exit(f"no usable rows in {csv_path}")

    agg = (df.groupby(["kernel", "workload"], as_index=False)
             .agg(walltime_s=("walltime_s", "median"),
                  n=("walltime_s", "size")))

    rel = []
    for kernel, sub in agg.groupby("kernel"):
        base = sub[sub.workload == "dram"]
        if base.empty:
            continue
        sub = sub.assign(rel_perf=base.iloc[0].walltime_s / sub["walltime_s"])
        rel.append(sub)
    agg_rel = pd.concat(rel) if rel else agg

    out_dir.mkdir(parents=True, exist_ok=True)
    stem = csv_path.stem
    _bar(agg, "walltime_s", "wall time (s)",
         f"soar-microbench wall time — {stem}",
         out_dir / f"{stem}.walltime.png")
    if "rel_perf" in agg_rel.columns:
        _bar(agg_rel, "rel_perf", "relative perf (t_dram / t_x)",
             f"normalized perf vs All-DRAM — {stem}",
             out_dir / f"{stem}.relperf.png")
    if show:
        plt.show()


def _bar(agg, value_col, ylabel, title, out_path):
    import matplotlib.pyplot as plt
    kernels = sorted(agg["kernel"].unique())
    workloads = [w for w in WORKLOADS if w in agg["workload"].unique()]
    x = list(range(len(workloads)))
    width = 0.8 / max(len(kernels), 1)

    fig, ax = plt.subplots(figsize=(max(7, 1.5 * len(workloads)), 5))
    for i, k in enumerate(kernels):
        sub = agg[agg.kernel == k].set_index("workload")
        vals = [sub.loc[w, value_col] if w in sub.index else 0 for w in workloads]
        offset = (i - (len(kernels) - 1) / 2) * width
        bars = ax.bar([xi + offset for xi in x], vals, width, label=k)
        for b, v in zip(bars, vals):
            if v > 0:
                ax.annotate(f"{v:.2f}", (b.get_x() + b.get_width() / 2, v),
                            ha="center", va="bottom", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels([WORKLOAD_LABELS.get(w, w) for w in workloads])
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(title="kernel", loc="best")
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

    pr = sub.add_parser("run", help="execute workloads, append CSV")
    pr.add_argument("workloads", nargs="+",
                    help=f"any of {WORKLOADS + list(ALIASES)}")
    pr.add_argument("--reps", type=int, default=1)
    pr.add_argument("--iter", type=int, default=5,
                    help="-i passed to bench")
    pr.add_argument("--buf-a", type=int, default=2048, help="MB")
    pr.add_argument("--buf-b", type=int, default=2048, help="MB")
    pr.add_argument("--seq-mult", type=int, default=46)
    pr.add_argument("--dram-cap", default="3GB",
                    help="cgroup DRAM cap for memtis runs")
    pr.add_argument("--csv", help="output CSV path (default: results/<host>-<kernel>.csv)")
    pr.add_argument("--plot", action="store_true", help="render PNGs after run")
    pr.add_argument("--out-dir", help="plot output dir")
    pr.set_defaults(func=cmd_run)

    pp = sub.add_parser("plot", help="render PNGs from CSV")
    pp.add_argument("csv", nargs="?", help="(default: newest under results/)")
    pp.add_argument("--out-dir")
    pp.add_argument("--show", action="store_true")
    pp.set_defaults(func=cmd_plot)

    pv = sub.add_parser("revert", help="dax1.0 back to devdax")
    pv.set_defaults(func=cmd_revert)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
