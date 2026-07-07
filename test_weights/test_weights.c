/* Two-region MEMTIS weight test.
 *
 *   A: touched 2x
 *   B: touched 1x
 *
 * Flags (weights are MULTIPLES of neutral; scaled by AOL_SCALE internally):
 *   -s <mb>   region size, MB      (default 128)
 *   -l <n>    A's weight, xneutral, fractional ok (default 1 = neutral)
 *   -h <n>    B's weight, xneutral, fractional ok (default 4)
 *   With -h > 2*-l, B outranks A despite half the accesses.
 *   -l 1 -h 1 -> vanilla (A wins).
 *
 * Run inside the htmm cgroup after 'htmm_ctl start'.
 * Build: cc -O2 -o test_weights test_weights.c
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

struct htmm_weight_range {
    uint64_t start, len, weight;
};

#define HTMM_IOC_REGISTER _IOW('H', 1, struct htmm_weight_range)
#define AOL_SCALE 1024UL   /* neutral weight; must match kernel */

struct config {
	size_t   region_len;   /* bytes */
	uint64_t w_low;        /* fixed-point weight (AOL_SCALE units) */
	uint64_t w_high;
};

static void parse_args(int argc, char **argv, struct config *cfg)
{
	int opt;

	cfg->region_len = 128UL << 20;
	cfg->w_low      = 1 * AOL_SCALE;
	cfg->w_high     = 4 * AOL_SCALE;

	while ((opt = getopt(argc, argv, "s:l:h:")) != -1) {
		switch (opt) {
		case 's': cfg->region_len = strtoul(optarg, NULL, 0) << 20;           break;
		case 'l': cfg->w_low      = (uint64_t)(strtod(optarg, NULL) * AOL_SCALE); break;
		case 'h': cfg->w_high     = (uint64_t)(strtod(optarg, NULL) * AOL_SCALE); break;
		default:
			fprintf(stderr, "usage: %s [-s mb] [-l low_mult] [-h high_mult]\n",
				argv[0]);
			exit(1);
		}
	}
}

static int register_region(int fd, char *p, size_t len, uint64_t weight)
{
	memset(p, 1, len);   /* fault the pages in (slow for big regions) */
	struct htmm_weight_range r = { (uint64_t)(uintptr_t)p, len, weight };
	if (ioctl(fd, HTMM_IOC_REGISTER, &r) < 0) { perror("ioctl"); return -1; }
	return 0;
}

int main(int argc, char **argv)
{
	struct config cfg;
	parse_args(argc, argv, &cfg);
	size_t gap = 4096;

	/* line-buffered so the address lines below reach a redirected stdout
	 * immediately, before the slow memsets - the watcher parses them. */
	setvbuf(stdout, NULL, _IOLBF, 0);

	int fd = open("/dev/memtis", O_RDWR);
	if (fd < 0) { perror("open"); return 1; }

	/* One mmap covering A | guard | B, then mprotect the middle page to
	 * PROT_NONE. That forces a VMA split so A and B are separate VMAs (distinct
	 * numa_maps lines) with a deterministic gap - adjacent same-flag anon VMAs
	 * would otherwise merge into a single line. */
	char *base = mmap(NULL, 2 * cfg.region_len + gap, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) { perror("mmap"); return 1; }
	char *A = base;
	char *B = base + cfg.region_len + gap;
	if (mprotect(base + cfg.region_len, gap, PROT_NONE) < 0) { perror("mprotect"); return 1; }

	/* print the layout up front (before faulting) so the watcher has the
	 * addresses even while the memsets below are still running */
	printf("A(2x,low) : %p +%zuMB weight=%gx (=%lu)\n", (void *)A, cfg.region_len >> 20,
	       (double)cfg.w_low / AOL_SCALE,  (unsigned long)cfg.w_low);
	printf("B(1x,high): %p +%zuMB weight=%gx (=%lu)\n", (void *)B, cfg.region_len >> 20,
	       (double)cfg.w_high / AOL_SCALE, (unsigned long)cfg.w_high);
	printf("pid=%d hammering (A 2x, B 1x)...\n", getpid());

	if (register_region(fd, A, cfg.region_len, cfg.w_low))  return 1;
	if (register_region(fd, B, cfg.region_len, cfg.w_high)) return 1;

	for (;;) {
		for (int pass = 0; pass < 2; pass++)      /* A: twice */
			for (size_t i = 0; i < cfg.region_len; i += 64)
				A[i]++;
		for (size_t i = 0; i < cfg.region_len; i += 64)      /* B: once */
			B[i]++;
	}
}
