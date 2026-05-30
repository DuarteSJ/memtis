# Usage: sudo sh test.sh [workload ...]
# Workloads:
#   dram     all-on-DRAM
#   hot      pchase on Optane, seq on DRAM (high-count buffer wins fast tier)
#   cold     pchase on DRAM,   seq on Optane (low-count buffer wins fast tier)
#   opt      all-on-Optane
#   memtis   MEMTIS-managed, both buffers unbound, DRAM cap via cgroup
#   static   == dram hot cold opt
#   all      == static + memtis
#
# Examples:
#   sudo sh test.sh dram
#   sudo sh test.sh static
#   sudo sh test.sh memtis
#   sudo sh test.sh dram cold memtis

BENCH=./soar-microbench/src/bench
SCRIPTS=../scripts
ITER=${ITER:-2}
SEQ_MULT=${SEQ_MULT:-46}
BUF_A=${BUF_A:-2048}
BUF_B=${BUF_B:-2048}
DRAM_CAP=${DRAM_CAP:-3GB}

if [ $# -eq 0 ]; then
    sed -n '1,16p' "$0"
    exit 1
fi

# expand aliases
WORKLOADS=""
for w in "$@"; do
    case "$w" in
        static) WORKLOADS="$WORKLOADS dram hot cold opt" ;;
        all)    WORKLOADS="$WORKLOADS dram hot cold opt memtis" ;;
        dram|hot|cold|opt|memtis) WORKLOADS="$WORKLOADS $w" ;;
        *) echo "unknown workload: $w" >&2; exit 1 ;;
    esac
done

# ---- ensure node 2 (Optane) online as system-ram ----
DAX_MODE=$(daxctl list -d dax1.0 2>/dev/null | grep -oP '"mode":"\K[^"]+')
if [ "$DAX_MODE" != "system-ram" ]; then
    echo "dax1.0 mode = '$DAX_MODE'; reconfiguring to system-ram..."
    daxctl reconfigure-device dax1.0 --mode=system-ram
else
    echo "dax1.0 already system-ram"
fi

# wrap time to get more accurate timings
walltime() {
    local t0 t1
    t0=$(date +%s.%N)
    "$@" >/dev/null
    t1=$(date +%s.%N)
    echo "$t1 - $t0" | bc -l
}

run_dram()  { printf "All DRAM: ";                    walltime $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 0 -N 0 -S $SEQ_MULT; }
run_hot()   { printf "pchase Optane, seq DRAM: ";     walltime $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 2 -N 0 -S $SEQ_MULT; }
run_cold()  { printf "pchase DRAM, seq Optane: ";     walltime $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 0 -N 2 -S $SEQ_MULT; }
run_opt()   { printf "All Optane: ";                  walltime $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 2 -N 2 -S $SEQ_MULT; }

run_memtis() {
    printf "\n===MEMTIS managed (DRAM cap %s, both unbound)===\n\n" "$DRAM_CAP"

    $SCRIPTS/set_htmm_memcg.sh htmm remove 2>/dev/null
    $SCRIPTS/set_htmm_memcg.sh htmm $$ enable
    $SCRIPTS/set_mem_size.sh   htmm 0 $DRAM_CAP

    sleep 2
    walltime $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -S $SEQ_MULT
    sleep 1

    $SCRIPTS/set_htmm_memcg.sh htmm $$ disable
    $SCRIPTS/set_htmm_memcg.sh htmm remove
}

for w in $WORKLOADS; do
    run_$w
done
