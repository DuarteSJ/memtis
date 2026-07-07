#!/usr/bin/env bash
#
# run_test_weights.sh - prep the htmm cgroup + sampler, run the two-region
# weight test, and watch which region MEMTIS promotes to the fast tier.
#
# Caps the fast node below the 2-region working set so MEMTIS must choose. With
# a high --high weight, B (touched 1x) should beat A (touched 2x) and win the
# fast tier. Mirrors membench/scripts/managed_corun.sh. Run as root.
#
#   -d, --dram-mb <mb>    fast-node memory cap         (default 128)
#   -f, --fast-node <n>   fast (DRAM) node             (default 0)
#   -S, --slow-node <n>   slow-tier node               (default 2)
#   -s, --size-mb <mb>    region size per workload     (test_weights default)
#   -l, --low <w>         A's weight (low)             (test_weights default)
#   -H, --high <w>        B's weight (high)            (test_weights default)
#   -w, --watch <s>       placement poll interval, s   (default 5)
#   -h, --help
#
#   control (vanilla):   sudo ./run_test_weights.sh --low 1024 --high 1024
#   treatment (weights): sudo ./run_test_weights.sh --low 1024 --high 4096
#
set -u

HTMM_CTL="${HTMM_CTL:-$HOME/membench/src/htmm_ctl}"
TEST="${TEST:-./test_weights}"
CG_DIR=/sys/fs/cgroup
CG="$CG_DIR/htmm"

DRAM_MB=128
FAST_NODE=0
SLOW_NODE=2
REGION_MB=""         # unset -> test_weights default
W_LOW=""
W_HIGH=""
WATCH=5

usage() { grep '^#' "$0" | grep -v '^#!' | sed 's/^#\s\?//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dram-mb)   DRAM_MB=$2;   shift 2 ;;
        -f|--fast-node) FAST_NODE=$2; shift 2 ;;
        -S|--slow-node) SLOW_NODE=$2; shift 2 ;;
        -s|--size-mb)   REGION_MB=$2; shift 2 ;;
        -l|--low)       W_LOW=$2;     shift 2 ;;
        -H|--high)      W_HIGH=$2;    shift 2 ;;
        -w|--watch)     WATCH=$2;     shift 2 ;;
        -h|--help)      usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 2 ;;
    esac
done

# forward the region/weight knobs to test_weights (its flags are -s/-l/-h)
FWD=()
[[ -n $REGION_MB ]] && FWD+=(-s "$REGION_MB")
[[ -n $W_LOW     ]] && FWD+=(-l "$W_LOW")
[[ -n $W_HIGH    ]] && FWD+=(-h "$W_HIGH")

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

# grab the 0x... field regardless of position, strip the 0x
addr_of() { awk -v t="$1" 'index($0,t)==1 {for(i=1;i<=NF;i++) if(substr($i,1,2)=="0x"){print substr($i,3); exit}}' "$OUT"; }
A_ADDR=$(addr_of 'A(')
B_ADDR=$(addr_of 'B(')

# page counts on fast + slow nodes for the mmap starting at $1 (hex, no 0x)
region_stat() {
    local line n0 ns
    line=$(grep "^$1 " "/proc/$TPID/numa_maps" 2>/dev/null)
    [[ -z "$line" ]] && { echo "no-line"; return; }
    n0=$(sed -n 's/.*N'"$FAST_NODE"'=\([0-9]*\).*/\1/p' <<<"$line")
    ns=$(sed -n 's/.*N'"$SLOW_NODE"'=\([0-9]*\).*/\1/p' <<<"$line")
    echo "N$FAST_NODE=${n0:-0} N$SLOW_NODE=${ns:-0}"
}

echo
echo "A base=$A_ADDR  B base=$B_ADDR"
echo "watching pages every ${WATCH}s (N$FAST_NODE=fast, N$SLOW_NODE=slow); Ctrl-C to stop"
echo "expect B's N$FAST_NODE to climb above A's once cooling+migration settle"
while kill -0 "$TPID" 2>/dev/null; do
    sleep "$WATCH"
    printf "  A(2x,low)  %s      B(1x,high)  %s\n" \
        "$(region_stat "$A_ADDR")" "$(region_stat "$B_ADDR")"
done
