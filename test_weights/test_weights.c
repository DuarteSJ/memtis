/* Two-region MEMTIS weight test.
 *
 *   A: touched 2x
 *   B: touched 1x
 *
 * Flags:
 *   -s <mb>   region size, MB      (default 128)
 *   -l <w>    A's weight  (low)    (default 1024 = neutral)
 *   -h <w>    B's weight  (high)   (default 4096)
 *   With -h > 2*-l, B outranks A despite half the accesses.
 *   -l 1024 -h 1024 -> vanilla (A wins).
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

struct config {
	size_t   region_mb;
	uint64_t w_low;
	uint64_t w_high;
};

static void parse_args(int argc, char **argv, struct config *cfg)
{
	int opt;

	cfg->region_mb = 128;
	cfg->w_low     = 1024;
	cfg->w_high    = 4096;

	while ((opt = getopt(argc, argv, "s:l:h:")) != -1) {
		switch (opt) {
		case 's': cfg->region_mb = strtoul(optarg, NULL, 0);  break;
		case 'l': cfg->w_low     = strtoull(optarg, NULL, 0); break;
		case 'h': cfg->w_high    = strtoull(optarg, NULL, 0); break;
		default:
			fprintf(stderr, "usage: %s [-s mb] [-l low_weight] [-h high_weight]\n",
				argv[0]);
			exit(1);
		}
	}
}

static char *map_and_register(int fd, size_t len, uint64_t weight, const char *tag)
{
	char *p = mmap(NULL, len, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { perror("mmap"); return NULL; }
	memset(p, 1, len);
	struct htmm_weight_range r = { (uint64_t)(uintptr_t)p, len, weight };
	if (ioctl(fd, HTMM_IOC_REGISTER, &r) < 0) { perror("ioctl"); return NULL; }
	printf("%s: %p +%zuMB weight=%lu\n", tag, p, len >> 20, (unsigned long)weight);
	return p;
}

int main(int argc, char **argv)
{
	struct config cfg;
	parse_args(argc, argv, &cfg);
	size_t len = cfg.region_mb << 20;

	int fd = open("/dev/memtis", O_RDWR);
	if (fd < 0) { perror("open"); return 1; }

	char *A = map_and_register(fd, len, cfg.w_low,  "A(2x,low) ");
	/* guard page between A and B: adjacent same-flag anon VMAs get merged into
	 * one, collapsing them to a single numa_maps line. A different-prot VMA in
	 * between blocks the merge so each region stays its own line. */
	mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	char *B = map_and_register(fd, len, cfg.w_high, "B(1x,high)");
	if (!A || !B) return 1;
	printf("pid=%d hammering (A 2x, B 1x)...\n", getpid());
	fflush(stdout);   /* stdout is fully buffered when redirected to a file;
			   * flush now or the loop below never lets it out */

	for (;;) {
		for (int pass = 0; pass < 2; pass++)      /* A: twice */
			for (size_t i = 0; i < len; i += 64)
				A[i]++;
		for (size_t i = 0; i < len; i += 64)      /* B: once */
			B[i]++;
	}
}
