#!/usr/bin/env bash
# Calibrate a, b for the AOL K-curve on this machine.
#
# For each workload:
#   1. run on FAST tier (numactl --membind=$FAST), collect A1,A3,s_LLC,c
#      and wall time
#   2. run on SLOW tier (numactl --membind=$SLOW), collect wall time
#   3. compute AOL=A1/A3, P=s_LLC/c, S=(t_slow/t_fast)-1, K=S/P
#
# Then fit K = 1/(a + b/AOL) via linearization 1/K = a + b/AOL using
# ordinary least squares on the (1/AOL, 1/K) points.
#
# Env vars:
#   FAST  fast-tier NUMA node (default 0)
#   SLOW  slow-tier NUMA node (default 2)
#   DUR   per-run duration seconds (default 15)
#   OUT   CSV output file (default calibrate.csv)
set -euo pipefail

cd "$(dirname "$0")"
make -s

FAST=${FAST:-0}
SLOW=${SLOW:-2}
DUR=${DUR:-15}
OUT=${OUT:-calibrate.csv}

EVENTS=r010001b1,r000001b0,r060006a3,r0000003c

run_fast() {
    local logf=$(mktemp)
    local t0 t1
    t0=$(date +%s.%N)
    sudo perf stat -x, -e "$EVENTS" -a -- \
        numactl --membind=$FAST --cpunodebind=$FAST "$@" >/dev/null 2> "$logf"
    t1=$(date +%s.%N)
    awk -F, -v wall="$(echo "$t1 - $t0" | bc -l)" '
        /r010001b1/{a1=$1}
        /r000001b0/{a3=$1}
        /r060006a3/{s=$1}
        /r0000003c/{c=$1}
        END { printf "%s,%s,%s,%s,%s\n", a1, a3, s, c, wall }
    ' "$logf"
    rm -f "$logf"
}

run_slow() {
    local t0 t1
    t0=$(date +%s.%N)
    numactl --membind=$SLOW --cpunodebind=$FAST "$@" >/dev/null 2>&1
    t1=$(date +%s.%N)
    echo "$t1 - $t0" | bc -l
}

echo "workload,a1,a3,s_llc,c,t_fast,t_slow,AOL,P,S,K" > "$OUT"

run_workload() {
    local name="$1"; shift
    echo "=== $name ==="
    local fast slow
    fast=$(run_fast "$@")
    IFS=, read -r a1 a3 sllc c tfast <<< "$fast"
    slow=$(run_slow "$@")
    awk -v name="$name" -v a1="$a1" -v a3="$a3" -v sllc="$sllc" -v c="$c" \
        -v tf="$tfast" -v ts="$slow" '
        BEGIN {
            if (a3==0 || c==0 || tf==0) { print name",zero counter"; exit }
            aol = a1*1.0/a3
            P   = sllc*1.0/c
            S   = ts/tf - 1.0
            K   = (P>0) ? S/P : 0
            printf "%s,%s,%s,%s,%s,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f\n",
                name, a1, a3, sllc, c, tf, ts, aol, P, S, K
        }
    ' | tee -a "$OUT"
}

run_workload "pchase-1G"       ./pchase 1024 $DUR
run_workload "stream-256-1t"   ./stream 256 1 $DUR
run_workload "stream-256-4t"   ./stream 256 4 $DUR
run_workload "stream-256-8t"   ./stream 256 8 $DUR
run_workload "stream-1024-1t"  ./stream 1024 1 $DUR

# fit 1/K = a + b/AOL via OLS over rows where K is sane
echo
echo "=== fit ==="
awk -F, '
    NR>1 && $11+0 > 0 && $8+0 > 0 {
        x = 1.0/$8
        y = 1.0/$11
        sx += x; sy += y; sxx += x*x; sxy += x*y; n++
        printf "  point: AOL=%.2f  K=%.4f  -> (1/AOL=%.5f, 1/K=%.3f)\n", $8, $11, x, y
    }
    END {
        if (n < 2) { print "need >=2 sane points"; exit }
        denom = n*sxx - sx*sx
        b = (n*sxy - sx*sy) / denom
        a = (sy - b*sx) / n
        printf "\nfit:  a = %.4f   b = %.4f   (K = 1 / (a + b/AOL))\n", a, b
        printf "scaled defaults for kernel:\n"
        printf "  AOL_PARAM_A_SCALED = %d   (= %.4f * AOL_SCALE=1024)\n", int(a*1024+0.5), a
        printf "  AOL_PARAM_B        = %d\n", int(b+0.5)
    }
' "$OUT"
