/*
 * STREAM-like Triad. High MLP / few stalls-per-miss.
 * a[i] = b[i] + scale * c[i] over arrays sized > LLC; sequential
 * access -> hardware prefetcher + OoO -> high MLP -> low AOL.
 *
 * Usage: ./stream <array_MB_per_thread> <threads> <seconds>
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/mman.h>

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

struct args {
    size_t n;          /* elements per array */
    double seconds;
    uint64_t iters;
};

static void *worker(void *vp)
{
    struct args *a = vp;
    size_t n = a->n;
    size_t bytes = n * sizeof(double);
    double *A = aligned_alloc(64, bytes);
    double *B = aligned_alloc(64, bytes);
    double *C = aligned_alloc(64, bytes);
    if (!A || !B || !C) { perror("aligned_alloc"); return NULL; }
    madvise(A, bytes, MADV_HUGEPAGE);
    madvise(B, bytes, MADV_HUGEPAGE);
    madvise(C, bytes, MADV_HUGEPAGE);
    for (size_t i = 0; i < n; i++) { A[i] = 0; B[i] = 1.0; C[i] = 2.0; }
    double scale = 3.0;
    double t0 = now_s();
    uint64_t iters = 0;
    while (now_s() - t0 < a->seconds) {
        for (size_t i = 0; i < n; i++)
            A[i] = B[i] + scale * C[i];
        iters++;
    }
    a->iters = iters;
    if (A[0] == 1.0e-30) printf("x");
    free(A); free(B); free(C);
    return NULL;
}

int main(int argc, char **argv)
{
    size_t mb = (argc > 1) ? strtoull(argv[1], NULL, 10) : 256;
    int nthreads = (argc > 2) ? atoi(argv[2]) : 1;
    double secs = (argc > 3) ? strtod(argv[3], NULL) : 10.0;
    size_t n = mb * (1UL << 20) / sizeof(double);

    pthread_t *th = malloc(nthreads * sizeof(pthread_t));
    struct args *as = calloc(nthreads, sizeof(struct args));
    for (int i = 0; i < nthreads; i++) {
        as[i].n = n;
        as[i].seconds = secs;
        pthread_create(&th[i], NULL, worker, &as[i]);
    }
    uint64_t total_iters = 0;
    for (int i = 0; i < nthreads; i++) {
        pthread_join(th[i], NULL);
        total_iters += as[i].iters;
    }
    /* Triad = 3 arrays touched per iter, 2 flops per element */
    double gb = (double)total_iters * n * 3 * sizeof(double) / 1e9;
    fprintf(stderr, "stream: %d threads, %.2f GB/s aggregate (%.0f iters total)\n",
            nthreads, gb / secs, (double)total_iters);
    return 0;
}
