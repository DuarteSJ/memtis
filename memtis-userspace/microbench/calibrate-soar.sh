#!/usr/bin/env bash
# Calibrate a, b for AOL K-curve using the SoarAlto microbenchmark.
# https://github.com/MoatLab/SoarAlto/tree/main/src/microbenchmark
#
# Workflow per workload (pchase, stream):
#   1. Pilot on FAST tier with -i 1, measure wall time t1.
#   2. Pick -i ~= DUR / t1 (clamped to >=1) so both runs take roughly DUR.
#   3. Run on FAST tier under perf -> A1, A3, s_LLC, c, t_fast.
#   4. Run on SLOW tier (no perf) -> t_slow.
#   5. AOL = A1/A3, P = s_LLC/c, S = t_slow/t_fast - 1, K = S/P.
# OLS-fit 1/K = a + b/AOL over rows with K in (0, 1].
#
# Env:
#   BENCH    path to SoarAlto bench binary (default ~/SoarAlto/src/microbenchmark/src/bench)
#   FAST     fast NUMA node (default 0)
#   SLOW     slow NUMA node (default 2)
#   DUR      target seconds per run (default 15)
#   BUF_A    pchase buffer MB (default 1024)
#   BUF_B    sequential buffer MB (default 1024)
#   OUT      csv (default calibrate-soar.csv)
set -euo pipefail

BENCH=${BENCH:-$HOME/SoarAlto/src/microbenchmark/src/bench}
FAST=${FAST:-0}
SLOW=${SLOW:-2}
DUR=${DUR:-15}
BUF_A=${BUF_A:-1024}
BUF_B=${BUF_B:-1024}
OUT=${OUT:-calibrate-soar.csv}

EVENTS=r010001b1,r000001b0,r060006a3,r0000003c

[ -x "$BENCH" ] || { echo "bench not at $BENCH"; exit 1; }

walltime() {
    local t0 t1
    t0=$(date +%s.%N)
    "$@" >/dev/null 2>&1
    t1=$(date +%s.%N)
    echo "$t1 - $t0" | bc -l
}

# Run BENCH with given -R/-A/-B; -i is the variable being calibrated.
# SoarAlto pins thread to logical core 0 internally; we still numactl-bind memory.
pilot_iter() {
    local r="$1" buf_a="$2" buf_b="$3"
    local t
    t=$(walltime numactl --membind=$FAST \
        "$BENCH" -R "$r" -i 1 -A "$buf_a" -B "$buf_b")
    awk -v t="$t" -v dur="$DUR" 'BEGIN {
        i = int(dur / t + 0.5)
        if (i < 1) i = 1
        print i
    }'
}

run_fast_perf() {
    local logf=$(mktemp)
    local r="$1" iter="$2" buf_a="$3" buf_b="$4"
    local t0 t1
    t0=$(date +%s.%N)
    sudo perf stat -x, -e "$EVENTS" -- \
        numactl --membind=$FAST \
        "$BENCH" -R "$r" -i "$iter" -A "$buf_a" -B "$buf_b" >/dev/null 2> "$logf"
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
    local r="$1" iter="$2" buf_a="$3" buf_b="$4"
    walltime numactl --membind=$SLOW \
        "$BENCH" -R "$r" -i "$iter" -A "$buf_a" -B "$buf_b"
}

echo "workload,a1,a3,s_llc,c,t_fast,t_slow,AOL,P,S,K,iter" > "$OUT"

run_workload() {
    local name="$1" r="$2" buf_a="$3" buf_b="$4"
    echo "=== $name ==="
    local iter
    iter=$(pilot_iter "$r" "$buf_a" "$buf_b")
    echo "pilot -> iter=$iter"
    local fast slow
    fast=$(run_fast_perf "$r" "$iter" "$buf_a" "$buf_b")
    IFS=, read -r a1 a3 sllc c tfast <<< "$fast"
    slow=$(run_slow "$r" "$iter" "$buf_a" "$buf_b")
    awk -v name="$name" -v iter="$iter" -v a1="$a1" -v a3="$a3" \
        -v sllc="$sllc" -v c="$c" -v tf="$tfast" -v ts="$slow" '
        BEGIN {
            if (a3==0 || c==0 || tf==0) { print name",zero counter"; exit }
            aol = a1*1.0/a3
            P   = sllc*1.0/c
            S   = ts/tf - 1.0
            K   = (P>0) ? S/P : 0
            printf "%s,%s,%s,%s,%s,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%d\n",
                name, a1, a3, sllc, c, tf, ts, aol, P, S, K, iter
            printf "  diag: A1/c=%.3f (pchase ~1, stream ~0.1)\n", a1*1.0/c > "/dev/stderr"
        }
    ' | tee -a "$OUT"
}

run_workload "pchase"   0.0 "$BUF_A" "$BUF_B"
run_workload "mix"      0.5 "$BUF_A" "$BUF_B"
run_workload "stream"   1.0 "$BUF_A" "$BUF_B"

echo
echo "=== fit ==="
# Paper's empirical K in (0,1] assumes ~2x slow tier. On bigger gaps
# K can exceed 1; the K = 1/(a + b/AOL) hyperbola still applies with
# smaller a (asymptote 1/a). Accept all positive K.
awk -F, '
    NR>1 && $11+0 > 0 && $8+0 > 0 {
        x = 1.0/$8
        y = 1.0/$11
        sx += x; sy += y; sxx += x*x; sxy += x*y; n++
        printf "  point: %s  AOL=%.2f  K=%.4f  -> (1/AOL=%.5f, 1/K=%.3f)\n",
               $1, $8, $11, x, y
    }
    END {
        if (n < 2) {
            print "need >=2 sane points; rerun with different buffers"
            exit
        }
        denom = n*sxx - sx*sx
        b = (n*sxy - sx*sy) / denom
        a = (sy - b*sx) / n
        printf "\nfit:  a = %.4f   b = %.4f   (K = 1 / (a + b/AOL))\n", a, b
        printf "scaled defaults for kernel:\n"
        printf "  AOL_PARAM_A_SCALED = %d   (= %.4f * AOL_SCALE=1024)\n", int(a*1024+0.5), a
        printf "  AOL_PARAM_B        = %d\n", int(b+0.5)
    }
' "$OUT"
