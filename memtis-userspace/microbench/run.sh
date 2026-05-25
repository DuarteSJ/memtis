#!/usr/bin/env bash
# Step 1: counter sanity. Runs pchase and stream under perf stat, prints
# raw counter deltas and the computed aol_weight using a=0.5, b=67.
set -euo pipefail

cd "$(dirname "$0")"
make -s

EVENTS=r010001b1,r000001b0,r060006a3,r0000003c   # A1,A3,s_LLC,c
DUR=${DUR:-10}

run_one() {
    local label="$1"; shift
    local logf
    logf=$(mktemp)
    echo "=== $label ==="
    sudo perf stat -x, -e "$EVENTS" -a -- "$@" 2> "$logf"
    grep -E ',r0[0-9a-f]+,' "$logf" | awk -F, -v label="$label" '
    BEGIN { a1=0;a3=0;s=0;c=0 }
    /r010001b1/{a1=$1}
    /r000001b0/{a3=$1}
    /r060006a3/{s=$1}
    /r0000003c/{c=$1}
    END {
        if (c==0||a3==0) { printf "%s: counters zero\n", label; exit }
        SCALE = 1024
        aol = a1*1.0/a3
        P   = s*1.0/c
        K   = 1.0/(0.5 + 67.0/aol)
        S   = P*K
        w   = 1.0 + S
        printf "%s: A1=%.3e A3=%.3e s_LLC=%.3e c=%.3e | AOL=%.2f P=%.4f K=%.4f S=%.4f weight=%.4f (scaled=%d)\n", \
               label, a1, a3, s, c, aol, P, K, S, w, int(w*SCALE+0.5)
    }'
    rm -f "$logf"
}

# Pointer chase: low MLP, expect AOL > 100 cycles, K -> ~0.7+, large weight.
run_one "pchase 1G"           ./pchase 1024 $DUR

# STREAM: high MLP, expect AOL < 30 cycles, K small, weight near 1.
run_one "stream 256M/1t"      ./stream 256 1 $DUR
run_one "stream 256M/4t"      ./stream 256 4 $DUR
run_one "stream 256M/8t"      ./stream 256 8 $DUR

echo
echo "Idle baseline ($DUR s)"
run_one "idle"                sleep $DUR
