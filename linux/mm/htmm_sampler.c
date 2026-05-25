/*
 * memory access sampling for hugepage-aware tiered memory management.
 */
#include <linux/kthread.h>
#include <linux/memcontrol.h>
#include <linux/mempolicy.h>
#include <linux/sched.h>
#include <linux/perf_event.h>
#include <linux/delay.h>
#include <linux/sched/cputime.h>

#include "../kernel/events/internal.h"

#include <linux/htmm.h>

struct task_struct *access_sampling = NULL;
/* mem_event[cpu][event] and aol_events[cpu][counter] are indexed by linear
 * CPU id and sized to nr_cpu_ids. Entries outside the htmm cpumask stay NULL. */
struct perf_event ***mem_event;
static struct perf_event ***aol_events; /* per cpu: {A1, A3, s_LLC, c} */
static u64 aols_last_a1, aols_last_a3, aols_last_s_llc, aols_last_c;

static bool valid_va(unsigned long addr)
{
    if (!(addr >> (PGDIR_SHIFT + 9)) && addr != 0)
	return true;
    else
	return false;
}

static __u64 get_pebs_event(enum events e)
{
    switch (e) {
	case DRAMREAD:
	    return DRAM_LLC_LOAD_MISS;
	case NVMREAD:
	    if (!htmm_cxl_mode)
		return NVM_LLC_LOAD_MISS;
	    else
		return N_HTMMEVENTS;
	case MEMWRITE:
	    return ALL_STORES;
	case CXLREAD:
	    if (htmm_cxl_mode)
		return REMOTE_DRAM_LLC_LOAD_MISS;
	    else
		return N_HTMMEVENTS;
	default:
	    return N_HTMMEVENTS;
    }
}

static int __perf_event_open(__u64 config, __u64 config1, __u64 cpu,
	__u64 type, __u32 pid)
{
    struct perf_event_attr attr;
    struct file *file;
    int event_fd, __pid;

    memset(&attr, 0, sizeof(struct perf_event_attr));

    attr.type = PERF_TYPE_RAW;
    attr.size = sizeof(struct perf_event_attr);
    attr.config = config;
    attr.config1 = config1;
    if (config == ALL_STORES)
	attr.sample_period = htmm_inst_sample_period;
    else
	attr.sample_period = get_sample_period(0);
    attr.sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID | PERF_SAMPLE_ADDR;
    attr.disabled = 0;
    attr.exclude_kernel = 1;
    attr.exclude_hv = 1;
    attr.exclude_callchain_kernel = 1;
    attr.exclude_callchain_user = 1;
    attr.precise_ip = 1;
    attr.enable_on_exec = 1;

    if (pid == 0)
	__pid = -1;
    else
	__pid = pid;
	
    event_fd = htmm__perf_event_open(&attr, __pid, cpu, -1, 0);
    //event_fd = htmm__perf_event_open(&attr, -1, cpu, -1, 0);
    if (event_fd <= 0) {
	printk("[error htmm__perf_event_open failure] event_fd: %d\n", event_fd);
	return -1;
    }

    file = fget(event_fd);
    if (!file) {
	printk("invalid file\n");
	return -1;
    }
    mem_event[cpu][type] = fget(event_fd)->private_data;
    return 0;
}

static void aol_counters_release(void)
{
    int cpu, counter;

    if (!aol_events)
        return;
    for (cpu = 0; cpu < nr_cpu_ids; cpu++) {
        if (!aol_events[cpu])
            continue;
        for (counter = 0; counter < N_HTMMCOUNTERS; counter++) {
            if (aol_events[cpu][counter]) {
                perf_event_release_kernel(aol_events[cpu][counter]);
                aol_events[cpu][counter] = NULL;
            }
        }
        kfree(aol_events[cpu]);
        aol_events[cpu] = NULL;
    }
    kfree(aol_events);
    aol_events = NULL;
}

static int aol_counters_init(void)
{
    struct perf_event_attr attr;
    u64 configs[N_HTMMCOUNTERS] = {
        ORO_CYCLES_WITH_DEMAND_DATA_RD,  /* A1 */
        OFFCORE_REQUESTS_DEMAND_DATA_RD, /* A3 */
        CYCLE_ACTIVITY_STALLS_L3_MISS,   /* s_LLC */
        CPU_CLK_UNHALTED_THREAD,         /* c */
    };
    int cpu, counter;

    aol_events = kcalloc(nr_cpu_ids, sizeof(*aol_events), GFP_KERNEL);
    if (!aol_events)
        return -ENOMEM;

    for_each_htmm_cpu(cpu) {
        aol_events[cpu] = kcalloc(N_HTMMCOUNTERS, sizeof(**aol_events), GFP_KERNEL);
        if (!aol_events[cpu]) {
            aol_counters_release();
            return -ENOMEM;
        }
        for (counter = 0; counter < N_HTMMCOUNTERS; counter++) {
            struct perf_event *ev;

            memset(&attr, 0, sizeof(struct perf_event_attr));
            attr.type           = PERF_TYPE_RAW;
            attr.size           = sizeof(attr);
            attr.config         = configs[counter];
            attr.exclude_kernel = 0;
            attr.disabled       = 0;

            ev = perf_event_create_kernel_counter(&attr, cpu, NULL, NULL, NULL);
            if (IS_ERR(ev)) {
                int err = PTR_ERR(ev);
                pr_err("aol_counters_init: failed to create counter %d on cpu %d: %d\n",
                       counter, cpu, err);
                aol_events[cpu][counter] = NULL;
                aol_counters_release();
                return err;
            }
            aol_events[cpu][counter] = ev;
        }
    }
    return 0;
}

static void aol_read_and_update(void)
{
    u64 a1 = 0, a3 = 0, s_llc = 0, c = 0;
    u64 *sums[N_HTMMCOUNTERS] = { &a1, &a3, &s_llc, &c };
    u64 en, ru;
    int cpu, i;

    if (!aol_events)
        return;
    for_each_htmm_cpu(cpu) {
        if (!aol_events[cpu])
            continue;
        for (i = 0; i < N_HTMMCOUNTERS; i++) {
            u64 val;

            if (!aol_events[cpu][i])
                continue;
            val = perf_event_read_value(aol_events[cpu][i], &en, &ru);
            /* counter was enabled but never actually ran in this window: result is untrustworthy */
            if (en && !ru) {
                printk_ratelimited("aol_read_and_update: counter %d on cpu %d not running (en=%llu ru=%llu); skipping update\n",
                                   i, cpu, en, ru);
                return;
            }
            *sums[i] += val;
        }
    }

    update_aol_counters(a1 - aols_last_a1, a3 - aols_last_a3, s_llc - aols_last_s_llc, c - aols_last_c);
    aols_last_a1    = a1;
    aols_last_a3    = a3;
    aols_last_s_llc = s_llc;
    aols_last_c     = c;
}

static int pebs_init(pid_t pid, int node)
{
    int cpu, event;

    mem_event = kcalloc(nr_cpu_ids, sizeof(*mem_event), GFP_KERNEL);
    if (!mem_event)
	return -ENOMEM;

    printk("pebs_init\n");
    for_each_htmm_cpu(cpu) {
	mem_event[cpu] = kcalloc(N_HTMMEVENTS, sizeof(**mem_event), GFP_KERNEL);
	if (!mem_event[cpu])
	    return -ENOMEM;
	for (event = 0; event < N_HTMMEVENTS; event++) {
	    if (get_pebs_event(event) == N_HTMMEVENTS) {
		mem_event[cpu][event] = NULL;
		continue;
	    }

	    if (__perf_event_open(get_pebs_event(event), 0, cpu, event, pid))
		return -1;
	    if (htmm__perf_event_init(mem_event[cpu][event], BUFFER_SIZE))
		return -1;
	}
    }

    return 0;
}

static void pebs_disable(void)
{
    int cpu, event;

    printk("pebs disable\n");
    if (!mem_event)
	return;
    for_each_htmm_cpu(cpu) {
	if (!mem_event[cpu])
	    continue;
	for (event = 0; event < N_HTMMEVENTS; event++) {
	    if (mem_event[cpu][event])
		perf_event_disable(mem_event[cpu][event]);
	}
    }
}

static void pebs_enable(void)
{
    int cpu, event;

    printk("pebs enable\n");
    if (!mem_event)
	return;
    for_each_htmm_cpu(cpu) {
	if (!mem_event[cpu])
	    continue;
	for (event = 0; event < N_HTMMEVENTS; event++) {
	    if (mem_event[cpu][event])
		perf_event_enable(mem_event[cpu][event]);
	}
    }
}

static void pebs_update_period(uint64_t value, uint64_t inst_value)
{
    int cpu, event;

    if (!mem_event)
	return;
    for_each_htmm_cpu(cpu) {
	if (!mem_event[cpu])
	    continue;
	for (event = 0; event < N_HTMMEVENTS; event++) {
	    int ret;
	    if (!mem_event[cpu][event])
		continue;

	    switch (event) {
		case DRAMREAD:
		case NVMREAD:
		case CXLREAD:
		    ret = perf_event_period(mem_event[cpu][event], value);
		    break;
		case MEMWRITE:
		    ret = perf_event_period(mem_event[cpu][event], inst_value);
		    break;
		default:
		    ret = 0;
		    break;
	    }

	    if (ret == -EINVAL)
		printk("failed to update sample period");
	}
    }
}

static int ksamplingd(void *data)
{
    unsigned long long nr_sampled = 0, nr_dram = 0, nr_nvm = 0, nr_write = 0;
    unsigned long long nr_throttled = 0, nr_lost = 0, nr_unknown = 0;
    unsigned long long nr_skip = 0;

    /* used for calculating average cpu usage of ksampled */
    struct task_struct *t = current;
    /* a unit of cputime: permil (1/1000) */
    u64 total_runtime, exec_runtime, cputime = 0;
    unsigned long total_cputime, elapsed_cputime, cur;
    /* used for periodic checks*/
    unsigned long cpucap_period = msecs_to_jiffies(15000); // 15s
    unsigned long sample_period = 0;
    unsigned long sample_inst_period = 0;
    unsigned long aol_period = msecs_to_jiffies(1000); /* TODO: this has to be tunned. Currently 1s as per SOAR/ALTO paper */
    unsigned long last_aol_update = jiffies;
    /* report cpu/period stat */
    unsigned long trace_cputime, trace_period = msecs_to_jiffies(1500); // 3s
    unsigned long trace_runtime;
    /* for timeout */ 
    unsigned long sleep_timeout;

    /* for analytic purpose */
    unsigned long hr_dram = 0, hr_nvm = 0;
    unsigned long aol_weight = get_current_aol_weight();

    /* orig impl: see read_sum_exec_runtime() */
    trace_runtime = total_runtime = exec_runtime = t->se.sum_exec_runtime;

    trace_cputime = total_cputime = elapsed_cputime = jiffies;
    sleep_timeout = usecs_to_jiffies(2000);

    /* TODO implements per-CPU node ksamplingd by using pg_data_t */
    /* Currently uses a single CPU node(0) */
    const struct cpumask *cpumask = cpumask_of_node(0);
    if (!cpumask_empty(cpumask))
	do_set_cpus_allowed(access_sampling, cpumask);

    while (!kthread_should_stop()) {
	int cpu, event, cond = false;
    
	if (htmm_mode == HTMM_NO_MIG) {
	    msleep_interruptible(10000);
	    continue;
	}
	
	for_each_htmm_cpu(cpu) {
	    if (!mem_event[cpu])
		continue;
	    for (event = 0; event < N_HTMMEVENTS; event++) {
		do {
		    struct perf_buffer *rb;
		    struct perf_event_mmap_page *up;
		    struct perf_event_header *ph;
		    struct htmm_event *he;
		    unsigned long pg_index, offset;
		    int page_shift;
		    __u64 head;

		    if (!mem_event[cpu][event]) {
			//continue;
			break;
		    }

		    __sync_synchronize();

		    rb = mem_event[cpu][event]->rb;
		    if (!rb) {
			printk("event->rb is NULL\n");
			return -1;
		    }
		    /* perf_buffer is ring buffer */
		    up = READ_ONCE(rb->user_page);
		    head = READ_ONCE(up->data_head);
		    if (head == up->data_tail) {
			if (cpu < 16)
			    nr_skip++;
			//continue;
			break;
		    }

		    head -= up->data_tail;
		    if (head > (BUFFER_SIZE * ksampled_max_sample_ratio / 100)) {
			cond = true;
		    } else if (head < (BUFFER_SIZE * ksampled_min_sample_ratio / 100)) {
			cond = false;
		    }

		    /* read barrier */
		    smp_rmb();

		    page_shift = PAGE_SHIFT + page_order(rb);
		    /* get address of a tail sample */
		    offset = READ_ONCE(up->data_tail);
		    pg_index = (offset >> page_shift) & (rb->nr_pages - 1);
		    offset &= (1 << page_shift) - 1;

		    ph = (void*)(rb->data_pages[pg_index] + offset);
		    switch (ph->type) {
			case PERF_RECORD_SAMPLE:
			    he = (struct htmm_event *)ph;
			    if (!valid_va(he->addr)) {
				break;
			    }

			    update_pginfo(he->pid, he->addr, event, aol_weight);
			    //count_vm_event(HTMM_NR_SAMPLED);
			    nr_sampled++;

			    if (event == DRAMREAD) {
				nr_dram++;
				hr_dram++;
			    }
			    else if (event == CXLREAD || event == NVMREAD) {
				nr_nvm++;
				hr_nvm++;
			    }
			    else
				nr_write++;
			    break;
			case PERF_RECORD_THROTTLE:
			case PERF_RECORD_UNTHROTTLE:
			    nr_throttled++;
			    break;
			case PERF_RECORD_LOST_SAMPLES:
			    nr_lost ++;
			    break;
			default:
			    nr_unknown++;
			    break;
		    }
		    if (nr_sampled % 500000 == 0) {
			trace_printk("nr_sampled: %llu, nr_dram: %llu, nr_nvm: %llu, nr_write: %llu, nr_throttled: %llu \n", nr_sampled, nr_dram, nr_nvm, nr_write,
				nr_throttled);
			nr_dram = 0;
			nr_nvm = 0;
			nr_write = 0;
		    }
		    /* read, write barrier */
		    smp_mb();
		    WRITE_ONCE(up->data_tail, up->data_tail + ph->size);
		} while (cond);
	    }
	}
	/* if ksampled_soft_cpu_quota is zero, disable dynamic pebs feature */
	if (!ksampled_soft_cpu_quota)
	    continue;

	/* sleep */
	schedule_timeout_interruptible(sleep_timeout);

	/* check elasped time */
	cur = jiffies;
    if ((cur - last_aol_update) >= aol_period) {
        aol_read_and_update();
        aol_weight = get_current_aol_weight();
        last_aol_update = cur;
    }
	if ((cur - elapsed_cputime) >= cpucap_period) {
	    u64 cur_runtime = t->se.sum_exec_runtime;
	    exec_runtime = cur_runtime - exec_runtime; //ns
	    elapsed_cputime = jiffies_to_usecs(cur - elapsed_cputime); //us
	    if (!cputime) {
		u64 cur_cputime = div64_u64(exec_runtime, elapsed_cputime);
		// EMA with the scale factor (0.2)
		cputime = ((cur_cputime << 3) + (cputime << 1)) / 10;
	    } else
		cputime = div64_u64(exec_runtime, elapsed_cputime);

	    /* to prevent frequent updates, allow for a slight variation of +/- 0.5% */
	    if (cputime > (ksampled_soft_cpu_quota + 5) &&
		    sample_period != pcount) {
		/* need to increase the sample period */
		/* only increase by 1 */
		unsigned long tmp1 = sample_period, tmp2 = sample_inst_period;
		increase_sample_period(&sample_period, &sample_inst_period);
		if (tmp1 != sample_period || tmp2 != sample_inst_period)
		    pebs_update_period(get_sample_period(sample_period),
				       get_sample_inst_period(sample_inst_period));
	    } else if (cputime < (ksampled_soft_cpu_quota - 5) && sample_period) {
		unsigned long tmp1 = sample_period, tmp2 = sample_inst_period;
		decrease_sample_period(&sample_period, &sample_inst_period);
		if (tmp1 != sample_period || tmp2 != sample_inst_period)
		    pebs_update_period(get_sample_period(sample_period),
				    get_sample_inst_period(sample_inst_period));
	    }
	    /* does it need to prevent ping-pong behavior? */
	    
	    elapsed_cputime = cur;
	    exec_runtime = cur_runtime;
	}

	/* This is used for reporting the sample period and cputime */
	if (cur - trace_cputime >= trace_period) {
	    unsigned long hr = 0;
	    u64 cur_runtime = t->se.sum_exec_runtime;
	    trace_runtime = cur_runtime - trace_runtime;
	    trace_cputime = jiffies_to_usecs(cur - trace_cputime);
	    trace_cputime = div64_u64(trace_runtime, trace_cputime);
	    
	    if (hr_dram + hr_nvm == 0)
		hr = 0;
	    else
		hr = hr_dram * 10000 / (hr_dram + hr_nvm);
	    trace_printk("sample_period: %lu || cputime: %lu  || hit ratio: %lu\n",
		    get_sample_period(sample_period), trace_cputime, hr);
	    
	    hr_dram = hr_nvm = 0;
	    trace_cputime = cur;
	    trace_runtime = cur_runtime;
	}
    }

    total_runtime = (t->se.sum_exec_runtime) - total_runtime; // ns
    total_cputime = jiffies_to_usecs(jiffies - total_cputime); // us

    printk("nr_sampled: %llu, nr_throttled: %llu, nr_lost: %llu\n", nr_sampled, nr_throttled, nr_lost);
    printk("total runtime: %llu ns, total cputime: %lu us, cpu usage: %llu\n",
	    total_runtime, total_cputime, (total_runtime) / total_cputime);

    return 0;
}

static int ksamplingd_run(void)
{
    int err = 0;
    
    if (!access_sampling) {
	access_sampling = kthread_run(ksamplingd, NULL, "ksamplingd");
	if (IS_ERR(access_sampling)) {
	    err = PTR_ERR(access_sampling);
	    access_sampling = NULL;
	}
    }
    return err;
}

int ksamplingd_init(pid_t pid, int node)
{
    int ret;

    if (access_sampling)
	return 0;

    ret = pebs_init(pid, node);
    if (ret) {
	printk("htmm__perf_event_init failure... ERROR:%d\n", ret);
	return 0;
    }

    ret = aol_counters_init();
    if (ret) {
	pr_err("aol_counters_init failure... ERROR:%d\n", ret);
	pebs_disable();
	return ret;
    }

    return ksamplingd_run();
}

void ksamplingd_exit(void)
{
    if (access_sampling) {
	kthread_stop(access_sampling);
	access_sampling = NULL;
    }
    pebs_disable();
    aol_counters_release();
}
