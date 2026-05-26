#!/bin/bash
# Apply MEMTIS / htmm sysfs tunables.
# Values copied from memtis-userspace/scripts/run_bench.sh func_memtis_setting.
# Run as root (sysfs writes need it).

set -e

echo 199     > /sys/kernel/mm/htmm/htmm_sample_period
echo 100007  > /sys/kernel/mm/htmm/htmm_inst_sample_period
echo 1       > /sys/kernel/mm/htmm/htmm_thres_hot
echo 2       > /sys/kernel/mm/htmm/htmm_split_period
echo 100000  > /sys/kernel/mm/htmm/htmm_adaptation_period
echo 2000000 > /sys/kernel/mm/htmm/htmm_cooling_period
echo 2       > /sys/kernel/mm/htmm/htmm_mode               # HUGEPAGE_OPT
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
