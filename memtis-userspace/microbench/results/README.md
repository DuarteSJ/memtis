# results/

Each calibration run drops a CSV here. Filename convention:

```
<host>-<YYYY-MM-DD>.csv
```

(Or whatever `OUT` is set to when running `calibrate.sh`.)

CSV columns:

```
workload,a1,a3,s_llc,c,t_fast,t_slow,AOL,P,S,K,iter
```

Bottom of each run also prints the OLS fit:

```
fit:  a = ...   b = ...
AOL_PARAM_A_SCALED = ...
AOL_PARAM_B_SCALED = ...
```

Commit calibration CSVs so we have a paper trail of which `a, b` were
used on which machine.
