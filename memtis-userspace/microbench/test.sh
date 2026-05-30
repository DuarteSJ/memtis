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
ITER=${ITER:-5}
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

# ---- CSV output (append-only) ----
CSV=${CSV:-results/$(hostname)-$(uname -r).csv}
mkdir -p "$(dirname "$CSV")"
if [ ! -f "$CSV" ]; then
    echo "timestamp,kernel,workload,iter,buf_a_mb,buf_b_mb,seq_mult,dram_cap,pc_node,seq_node,walltime_s" > "$CSV"
fi

# wrap time to get more accurate timings
walltime() {
    local t0 t1
    t0=$(date +%s.%N)
    "$@" >/dev/null
    t1=$(date +%s.%N)
    echo "$t1 - $t0" | bc -l
}

# label, pc_node, seq_node, dram_cap, bench-args...
log_run() {
    local label="$1" pc="$2" seq="$3" cap="$4"
    shift 4
    local t
    t=$(walltime "$@")
    printf "%s: %s\n" "$label" "$t"
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$(date -Iseconds)" "$(uname -r)" "$label" \
        "$ITER" "$BUF_A" "$BUF_B" "$SEQ_MULT" "$cap" "$pc" "$seq" "$t" \
        >> "$CSV"
}

run_dram()  { log_run dram 0 0 - $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 0 -N 0 -S $SEQ_MULT; }
run_hot()   { log_run hot  2 0 - $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 2 -N 0 -S $SEQ_MULT; }
run_cold()  { log_run cold 0 2 - $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 0 -N 2 -S $SEQ_MULT; }
run_opt()   { log_run opt  2 2 - $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -r 2 -N 2 -S $SEQ_MULT; }

run_memtis() {
    printf "\n===MEMTIS managed (DRAM cap %s, both unbound)===\n" "$DRAM_CAP"

    $SCRIPTS/set_htmm_memcg.sh htmm remove 2>/dev/null
    $SCRIPTS/set_htmm_memcg.sh htmm $$ enable
    $SCRIPTS/set_mem_size.sh   htmm 0 $DRAM_CAP

    sleep 2
    log_run memtis -1 -1 "$DRAM_CAP" $BENCH -R 0.5 -i $ITER -A $BUF_A -B $BUF_B -S $SEQ_MULT
    sleep 1

    $SCRIPTS/set_htmm_memcg.sh htmm $$ disable
    $SCRIPTS/set_htmm_memcg.sh htmm remove
}

for w in $WORKLOADS; do
    run_$w
done
