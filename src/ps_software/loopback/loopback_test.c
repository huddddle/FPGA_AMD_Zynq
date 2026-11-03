#define _POSIX_C_SOURCE 200809L
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "y26_dma_uapi.h"

_Static_assert(sizeof(struct y26_dma_transfer) == 32, "DMA ABI must be 32 bytes");

struct options {
    const char *device;
    uint32_t bytes;
    uint32_t iterations;
    uint32_t seed;
    uint32_t timeout_ms;
};

static void usage(FILE *stream)
{
    fputs("usage: loopback_test [--device PATH] [--bytes N] [--iterations N]\n"
          "                     [--seed N] [--timeout-ms N] [--help]\n"
          "  bytes: 4..4096, multiple of 4; iterations: 1..4294967295\n"
          "  timeout-ms: 1..5000; seed: uint32; numbers: decimal or 0x hexadecimal\n"
          "  defaults: /dev/y26_dma_loopback, 64 bytes, 100 iterations,\n"
          "            seed 0x12345678, timeout 1000 ms per transfer\n", stream);
}

static int parse_u32(const char *text, uint32_t *value)
{
    char *end;
    if (!text[0] || !isdigit((unsigned char)text[0]))
        return -1;
    int base = (text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) ? 16 : 10;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, base);
    if (errno || end == text || *end || parsed > UINT32_MAX)
        return -1;
    *value = (uint32_t)parsed;
    return 0;
}

static void fill_pattern(uint32_t *buffer, size_t words, uint32_t iteration,
                         uint32_t *state)
{
    for (size_t i = 0; i < words; ++i) {
        switch (iteration % 4U) {
        case 0:
            buffer[i] = (uint32_t)i + 1U;
            break;
        case 1:
            buffer[i] = 0;
            break;
        case 2:
            buffer[i] = UINT32_MAX;
            break;
        default:
            *state = *state * UINT32_C(1664525) + UINT32_C(1013904223);
            buffer[i] = *state;
            break;
        }
    }
}

static double elapsed_ms(const struct timespec *start, const struct timespec *end)
{
    return (double)(end->tv_sec - start->tv_sec) * 1000.0 +
           (double)(end->tv_nsec - start->tv_nsec) / 1000000.0;
}

int main(int argc, char **argv)
{
    enum { OPT_DEVICE = 1000, OPT_BYTES, OPT_ITERATIONS, OPT_SEED, OPT_TIMEOUT };
    static const struct option long_options[] = {
        {"device", required_argument, NULL, OPT_DEVICE},
        {"bytes", required_argument, NULL, OPT_BYTES},
        {"iterations", required_argument, NULL, OPT_ITERATIONS},
        {"seed", required_argument, NULL, OPT_SEED},
        {"timeout-ms", required_argument, NULL, OPT_TIMEOUT},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0}
    };
    struct options opts = {
        .device = "/dev/y26_dma_loopback",
        .bytes = 64,
        .iterations = 100,
        .seed = UINT32_C(0x12345678),
        .timeout_ms = 1000,
    };
    int option;
    opterr = 0;
    while ((option = getopt_long(argc, argv, "", long_options, NULL)) != -1) {
        uint32_t *value;
        switch (option) {
        case OPT_DEVICE:
            opts.device = optarg;
            continue;
        case OPT_BYTES:
            value = &opts.bytes;
            break;
        case OPT_ITERATIONS:
            value = &opts.iterations;
            break;
        case OPT_SEED:
            value = &opts.seed;
            break;
        case OPT_TIMEOUT:
            value = &opts.timeout_ms;
            break;
        case 'h':
            usage(stdout);
            return 0;
        default:
            fputs("invalid or incomplete option\n", stderr);
            usage(stderr);
            return 2;
        }
        if (parse_u32(optarg, value) != 0) {
            fprintf(stderr, "invalid numeric value: %s\n", optarg);
            usage(stderr);
            return 2;
        }
    }
    if (optind != argc || !opts.device[0] || opts.bytes < 4 ||
        opts.bytes > Y26_DMA_MAX_BYTES || (opts.bytes & 3U) ||
        opts.iterations == 0 || opts.timeout_ms == 0 || opts.timeout_ms > 5000) {
        fputs("invalid transfer parameters\n", stderr);
        usage(stderr);
        return 2;
    }

    uint32_t tx[Y26_DMA_MAX_BYTES / sizeof(uint32_t)];
    uint32_t rx[Y26_DMA_MAX_BYTES / sizeof(uint32_t)];
    uint32_t state = opts.seed;
    double ioctl_total_ms = 0.0;
    int fd = open(opts.device, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        int saved_errno = errno;
        fprintf(stderr, "open %s: %s (errno=%d)\n",
                opts.device, strerror(saved_errno), saved_errno);
        return 1;
    }

    for (uint32_t iteration = 0; iteration < opts.iterations; ++iteration) {
        struct timespec start, end;
        fill_pattern(tx, opts.bytes / sizeof(uint32_t), iteration, &state);
        memset(rx, 0xa5, opts.bytes);
        struct y26_dma_transfer transfer = {
            .bytes = opts.bytes,
            .timeout_ms = opts.timeout_ms,
            .tx_user = (uintptr_t)tx,
            .rx_user = (uintptr_t)rx,
        };
        if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
            int saved_errno = errno;
            fprintf(stderr, "clock_gettime: %s (errno=%d)\n",
                    strerror(saved_errno), saved_errno);
            close(fd);
            return 1;
        }
        if (ioctl(fd, Y26_DMA_TRANSFER, &transfer) < 0) {
            int saved_errno = errno;
            fprintf(stderr, "iteration=%" PRIu32 " ioctl: %s (errno=%d)\n",
                    iteration, strerror(saved_errno), saved_errno);
            close(fd);
            return 1;
        }
        if (clock_gettime(CLOCK_MONOTONIC, &end) != 0) {
            int saved_errno = errno;
            fprintf(stderr, "clock_gettime: %s (errno=%d)\n",
                    strerror(saved_errno), saved_errno);
            close(fd);
            return 1;
        }
        ioctl_total_ms += elapsed_ms(&start, &end);
        if (transfer.completed != (Y26_DMA_DONE_TX | Y26_DMA_DONE_RX) ||
            transfer.bytes != opts.bytes) {
            fprintf(stderr, "iteration=%" PRIu32 " incomplete completed=0x%" PRIx32
                    " returned_bytes=%" PRIu32 "\n",
                    iteration, transfer.completed, transfer.bytes);
            close(fd);
            return 1;
        }
        const unsigned char *expected = (const unsigned char *)tx;
        const unsigned char *actual = (const unsigned char *)rx;
        size_t mismatches = 0, first = 0;
        for (size_t i = 0; i < opts.bytes; ++i) {
            if (expected[i] != actual[i]) {
                if (mismatches == 0)
                    first = i;
                ++mismatches;
            }
        }
        if (mismatches != 0) {
            fprintf(stderr,
                    "iteration=%" PRIu32 " first_mismatch_byte=%zu expected=0x%02x "
                    "actual=0x%02x mismatches=%zu\n",
                    iteration, first, expected[first], actual[first], mismatches);
            close(fd);
            return 1;
        }
    }
    if (close(fd) != 0) {
        int saved_errno = errno;
        fprintf(stderr, "close: %s (errno=%d)\n", strerror(saved_errno), saved_errno);
        return 1;
    }
    printf("backend=PL_DMA bytes=%" PRIu32 " iterations=%" PRIu32
           " seed=0x%08" PRIx32 " compared_bytes=%" PRIu64
           " mismatches=0 ioctl_total_ms=%.3f ioctl_avg_ms=%.3f\n",
           opts.bytes, opts.iterations, opts.seed,
           (uint64_t)opts.bytes * opts.iterations,
           ioctl_total_ms, ioctl_total_ms / opts.iterations);
    return 0;
}
