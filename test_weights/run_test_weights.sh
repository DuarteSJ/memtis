#!/usr/bin/env bash
#
# run_test_weights.sh - prep the htmm cgroup + sampler, run the two-region
# weight test, and watch which region MEMTIS promotes to the fast tier.
#
# Caps the fast node below the 2-region working set so MEMTIS must choose. With
# a high --high weight, B (touched 1x) should beat A (touched 2x) and win the
# fast tier. Mirrors membench/scripts/managed_corun.sh. Run as root.
#
#   -d, --dram-mb <mb>    fast-node memory cap         (default = --size-mb)
#   -f, --fast-node <n>   fast (DRAM) node             (default 0)
#   -S, --slow-node <n>   slow-tier node               (default 2)
#   -s, --size-mb <mb>    region size per workload     (default 128)
#   -l, --low <n>         A's weight, xneutral         (default 1)
#   -H, --high <n>        B's weight, xneutral         (default 4)
#   -o, --order <A|B>     region faulted first         (default A)
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

DRAM_MB=""           # unset -> defaults to REGION_MB (fast tier fits one region)
FAST_NODE=0
SLOW_NODE=2
REGION_MB=128        # per-region size
W_LOW=""
W_HIGH=""
ORDER=""             # A|B: which region is faulted first (first-touch)
WATCH=5

# print the leading comment block only (skip shebang, stop at first non-# line)
usage() { awk 'NR>1 && /^#/{sub(/^#\s?/,"");print;next} NR>1{exit}' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dram-mb)   DRAM_MB=$2;   shift 2 ;;
        -f|--fast-node) FAST_NODE=$2; shift 2 ;;
        -S|--slow-node) SLOW_NODE=$2; shift 2 ;;
        -s|--size-mb)   REGION_MB=$2; shift 2 ;;
        -l|--low)       W_LOW=$2;     shift 2 ;;
        -H|--high)      W_HIGH=$2;    shift 2 ;;
        -o|--order)     ORDER=$2;     shift 2 ;;
        -w|--watch)     WATCH=$2;     shift 2 ;;
        -h|--help)      usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 2 ;;
    esac
done

# DRAM cap defaults to one region, so exactly one of the two fits in fast tier
[[ -z $DRAM_MB ]] && DRAM_MB=$REGION_MB

# forward the region/weight knobs to test_weights (its flags are -s/-l/-h)
FWD=(-s "$REGION_MB")
[[ -n $W_LOW  ]] && FWD+=(-l "$W_LOW")
[[ -n $W_HIGH ]] && FWD+=(-h "$W_HIGH")
[[ -n $ORDER  ]] && FWD+=(-o "$ORDER")

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -x "$TEST" ]]     || { echo "build $TEST first: cc -O2 -o test_weights test_weights.c" >&2; exit 1; }
[[ -x "$HTMM_CTL" ]] || { echo "htmm_ctl not at '$HTMM_CTL'; set HTMM_CTL=/path/to/htmm_ctl" >&2; exit 1; }
[[ -d /sys/kernel/mm/htmm ]] || { echo "not on the htmm kernel" >&2; exit 1; }

htmm_setting() {
    echo "${HTMM_SAMPLE_PERIOD:-199}"          > /sys/kernel/mm/htmm/htmm_sample_period
    echo "${HTMM_INST_SAMPLE_PERIOD:-100007}"  > /sys/kernel/mm/htmm/htmm_inst_sample_period
    echo "${HTMM_THRES_HOT:-1}"                > /sys/kernel/mm/htmm/htmm_thres_hot
    echo "${HTMM_SPLIT_PERIOD:-2}"             > /sys/kernel/mm/htmm/htmm_split_period
    echo "${HTMM_ADAPTATION_PERIOD:-100000}"   > /sys/kernel/mm/htmm/htmm_adaptation_period
    echo "${HTMM_COOLING_PERIOD:-2000000}"     > /sys/kernel/mm/htmm/htmm_cooling_period
    echo "${HTMM_MODE:-2}"                     > /sys/kernel/mm/htmm/htmm_mode
    echo "${HTMM_DEMOTION_PERIOD_IN_MS:-500}"  > /sys/kernel/mm/htmm/htmm_demotion_period_in_ms
    echo "${HTMM_PROMOTION_PERIOD_IN_MS:-500}" > /sys/kernel/mm/htmm/htmm_promotion_period_in_ms
    echo "${HTMM_GAMMA:-4}"                    > /sys/kernel/mm/htmm/htmm_gamma
    echo "${KSAMPLED_SOFT_CPU_QUOTA:-30}"      > /sys/kernel/mm/htmm/ksampled_soft_cpu_quota
    echo "${HTMM_THRES_SPLIT:-1}"              > /sys/kernel/mm/htmm/htmm_thres_split
    echo "${HTMM_NOWARM:-0}"                   > /sys/kernel/mm/htmm/htmm_nowarm
    echo "${HTMM_CXL_MODE:-disabled}"          > /sys/kernel/mm/htmm/htmm_cxl_mode
    echo "${THP_ENABLED:-always}"              > /sys/kernel/mm/transparent_hugepage/enabled
    echo "${THP_DEFRAG:-always}"               > /sys/kernel/mm/transparent_hugepage/defrag
    echo "${NUMA_BALANCING:-0}"                > /proc/sys/kernel/numa_balancing
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

echo "DRAM cap node$FAST_NODE: ${DRAM_MB}MB    args: ${FWD[*]}"

echo $$ > "$CG/cgroup.procs"                 # shell in cgroup; child inherits
"$HTMM_CTL" start || { echo "htmm_ctl start failed" >&2; exit 1; }

# ---- run (background so we can watch numa placement) -----------------------
OUT="$(mktemp)"
"$TEST" "${FWD[@]}" > "$OUT" 2>&1 &
TPID=$!

# grab the 0x... field regardless of position, strip the 0x
addr_of() { awk -v t="$1" 'index($0,t)==1 {for(i=1;i<=NF;i++) if(substr($i,1,2)=="0x"){print substr($i,3); exit}}' "$OUT"; }

# wait (up to ~15s) for the address lines - big regions take a while to mmap
for _ in $(seq 30); do
    A_ADDR=$(addr_of 'A('); B_ADDR=$(addr_of 'B(')
    [[ -n $A_ADDR && -n $B_ADDR ]] && break
    kill -0 "$TPID" 2>/dev/null || { echo "test_weights exited early:" >&2; cat "$OUT" >&2; exit 1; }
    sleep 0.5
done
cat "$OUT"

# page counts on fast + slow nodes for the mmap starting at $1 (hex, no 0x)
region_stat() {
    local line n0 ns
    line=$(grep "^$1 " "/proc/$TPID/numa_maps" 2>/dev/null)
    [[ -z "$line" ]] && { echo "no-line"; return; }
    n0=$(sed -n 's/.*N'"$FAST_NODE"'=\([0-9]*\).*/\1/p' <<<"$line")
    ns=$(sed -n 's/.*N'"$SLOW_NODE"'=\([0-9]*\).*/\1/p' <<<"$line")
    echo "N$FAST_NODE=${n0:-0} N$SLOW_NODE=${ns:-0}"
}

while kill -0 "$TPID" 2>/dev/null; do
    sleep "$WATCH"
    printf "  A(2x,low)  %s      B(1x,high)  %s\n" \
        "$(region_stat "$A_ADDR")" "$(region_stat "$B_ADDR")"
done
