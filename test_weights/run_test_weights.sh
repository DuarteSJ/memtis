#!/usr/bin/env bash
#
# run_test_weights.sh - prep the htmm cgroup + sampler, run the two-region
# weight test, and watch which region MEMTIS promotes to the fast tier.
#
# Caps the fast (DRAM) node below the 2-region working set so MEMTIS must
# choose. With a high -h weight, B (touched 1x) should beat A (touched 2x) and
# win the fast tier - the whole point. Mirrors membench/scripts/managed_corun.sh.
#
# Must run on the htmm kernel, as root.
#   sudo ./run_test_weights.sh [-d dram_mb] [-f fast_node] \
#                              [-s region_mb] [-l low_w] [-h high_w] [-w watch_s]
#
#   control (vanilla):   sudo ./run_test_weights.sh -l 1024 -h 1024
#   treatment (weights): sudo ./run_test_weights.sh -l 1024 -h 4096
#
set -u

HTMM_CTL="${HTMM_CTL:-$HOME/membench/src/htmm_ctl}"
TEST="${TEST:-./test_weights}"
CG_DIR=/sys/fs/cgroup
CG="$CG_DIR/htmm"

DRAM_MB=128
FAST_NODE=0
WATCH=5
FWD=()               # -s/-l/-h forwarded to test_weights

while getopts "d:f:s:l:h:w:" o; do
    case "$o" in
        d) DRAM_MB="$OPTARG" ;;
        f) FAST_NODE="$OPTARG" ;;
        s) FWD+=(-s "$OPTARG") ;;
        l) FWD+=(-l "$OPTARG") ;;
        h) FWD+=(-h "$OPTARG") ;;
        w) WATCH="$OPTARG" ;;
        *) exit 2 ;;
    esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -x "$TEST" ]]     || { echo "build $TEST first: cc -O2 -o test_weights test_weights.c" >&2; exit 1; }
[[ -x "$HTMM_CTL" ]] || { echo "htmm_ctl not at '$HTMM_CTL'; set HTMM_CTL=/path/to/htmm_ctl" >&2; exit 1; }
[[ -d /sys/kernel/mm/htmm ]] || { echo "not on the htmm kernel" >&2; exit 1; }

htmm_setting() {
    echo 199     > /sys/kernel/mm/htmm/htmm_sample_period
    echo 100007  > /sys/kernel/mm/htmm/htmm_inst_sample_period
    echo 1       > /sys/kernel/mm/htmm/htmm_thres_hot
    echo 2       > /sys/kernel/mm/htmm/htmm_split_period
    echo 100000  > /sys/kernel/mm/htmm/htmm_adaptation_period
    echo 2000000 > /sys/kernel/mm/htmm/htmm_cooling_period
    echo 2       > /sys/kernel/mm/htmm/htmm_mode
    echo 500     > /sys/kernel/mm/htmm/htmm_demotion_period_in_ms
    echo 500     > /sys/kernel/mm/htmm/htmm_promotion_period_in_ms
    echo 4       > /sys/kernel/mm/htmm/htmm_gamma
    echo 30      > /sys/kernel/mm/htmm/ksampled_soft_cpu_quota
    echo 1       > /sys/kernel/mm/htmm/htmm_thres_split
    echo 0       > /sys/kernel/mm/htmm/htmm_nowarm
    echo disabled > /sys/kernel/mm/htmm/htmm_cxl_mode
    echo always  > /sys/kernel/mm/transparent_hugepage/enabled
    echo always  > /sys/kernel/mm/transparent_hugepage/defrag
    echo 0       > /proc/sys/kernel/numa_balancing
}

cleanup() {
    [[ -n "${TPID:-}" ]] && kill "$TPID" 2>/dev/null
    "$HTMM_CTL" stop 2>/dev/null || true
    echo disabled > "$CG/memory.htmm_enabled" 2>/dev/null || true
    echo $$ > "$CG_DIR/cgroup.procs" 2>/dev/null || true
    rm -f "${OUT:-}"
}
trap cleanup EXIT

# ---- prep ------------------------------------------------------------------
htmm_setting
echo 3 > /proc/sys/vm/drop_caches

rmdir "$CG" 2>/dev/null || true
mkdir -p "$CG"
echo "+memory" > "$CG_DIR/cgroup.subtree_control"
if [[ ! -e "$CG/memory.max_at_node${FAST_NODE}" ]]; then
    echo "no memory.max_at_node${FAST_NODE} - htmm per-node cap unsupported?" >&2
    exit 1
fi
echo $(( DRAM_MB * 1024 * 1024 )) > "$CG/memory.max_at_node${FAST_NODE}"
echo enabled > "$CG/memory.htmm_enabled"

echo "== two-region weight test =="
echo "DRAM cap node$FAST_NODE: ${DRAM_MB}MB    args: ${FWD[*]:-defaults}"
echo

echo $$ > "$CG/cgroup.procs"                 # shell in cgroup; child inherits
"$HTMM_CTL" start || { echo "htmm_ctl start failed" >&2; exit 1; }

# ---- run (background so we can watch numa placement) -----------------------
OUT="$(mktemp)"
"$TEST" "${FWD[@]}" > "$OUT" 2>&1 &
TPID=$!
sleep 1
cat "$OUT"

A_ADDR=$(awk '/^A\(/{print $2}' "$OUT" | sed 's/^0x//')
B_ADDR=$(awk '/^B\(/{print $2}' "$OUT" | sed 's/^0x//')

fast_pages() {   # $1=addr-nohex ; prints N<FAST_NODE> page count for that mmap
    local line
    line=$(grep "^$1 " "/proc/$TPID/numa_maps" 2>/dev/null)
    sed -n 's/.*N'"$FAST_NODE"'=\([0-9]*\).*/\1/p' <<<"$line"
}

echo
echo "watching fast-tier (node $FAST_NODE) page counts every ${WATCH}s; Ctrl-C to stop"
echo "expect B (high weight) to climb above A once cooling+migration settle"
while kill -0 "$TPID" 2>/dev/null; do
    sleep "$WATCH"
    a=$(fast_pages "$A_ADDR"); b=$(fast_pages "$B_ADDR")
    printf "  A(2x,low) fastN%s=%-8s   B(1x,high) fastN%s=%-8s\n" \
        "$FAST_NODE" "${a:-0}" "$FAST_NODE" "${b:-0}"
done
