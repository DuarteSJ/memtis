/*
 * Pointer-chase microbench. Low MLP / high stalls-per-miss.
 * Random permutation cycle through a buffer larger than LLC.
 * Each step depends on the previous load -> serialized -> AOL ~ raw latency.
 *
 * Usage: ./pchase <buf_MB> <seconds>
 *   buf_MB:  buffer size in MiB (default 1024). Must exceed LLC by >=4x.
 *   seconds: run duration (default 10).
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>

#define LINE 64

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    size_t mb = (argc > 1) ? strtoull(argv[1], NULL, 10) : 1024;
    double secs = (argc > 2) ? strtod(argv[2], NULL) : 10.0;
    size_t bytes = mb * (1UL << 20);
    size_t n = bytes / LINE;

    char *buf = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { perror("mmap"); return 1; }
    madvise(buf, bytes, MADV_HUGEPAGE);
    memset(buf, 0, bytes);

    /* Fisher-Yates over indices, then thread cache lines as a single cycle. */
    uint64_t *idx = malloc(n * sizeof(uint64_t));
    if (!idx) { perror("malloc"); return 1; }
    for (size_t i = 0; i < n; i++) idx[i] = i;
    srand(42);
    for (size_t i = n - 1; i > 0; i--) {
        size_t j = (size_t)rand() % (i + 1);
        uint64_t t = idx[i]; idx[i] = idx[j]; idx[j] = t;
    }
    for (size_t i = 0; i < n; i++) {
        uintptr_t cur = (uintptr_t)(buf + idx[i] * LINE);
        uintptr_t nxt = (uintptr_t)(buf + idx[(i + 1) % n] * LINE);
        *(uintptr_t *)cur = nxt;
    }
    free(idx);

    uintptr_t *p = (uintptr_t *)buf;
    uint64_t hops = 0;
    double t0 = now_s();
    double t = t0;
    while (t - t0 < secs) {
        for (int k = 0; k < (1 << 16); k++) {
            p = (uintptr_t *)*p;
        }
        hops += (1 << 16);
        t = now_s();
    }
    double elapsed = t - t0;
    fprintf(stderr, "pchase: %.2fs, %lu hops, %.1f ns/hop, %.2f Mhops/s\n",
            elapsed, (unsigned long)hops, elapsed * 1e9 / hops,
            hops / elapsed / 1e6);
    /* sink to prevent DCE */
    if ((uintptr_t)p == 0xdeadbeef) printf("x");
    return 0;
}
