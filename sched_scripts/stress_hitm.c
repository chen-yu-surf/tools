#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include <err.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <math.h>
#include <sys/time.h>

// Cache line size (x86-64 typical: 64 bytes) - critical for cache contention
#define CACHE_LINE_SIZE 64
#define BUFFER_SIZE 4096			// 4KB page-aligned buffer (64 cache lines)
#define INVALID_PTHREAD_ID ((pthread_t)-1)	// Invalid pthread ID sentinel

// Global shared LLC buffer pool (ALL THREADS SHARE THIS POOL)
char *shared_worker_buffer_pool = NULL;
// Mutex to protect pool initialization (only once)
pthread_mutex_t shared_worker_buffer_pool_mutex = PTHREAD_MUTEX_INITIALIZER;

static unsigned long cache_footprint_kb = 256;
static unsigned long matrix_size = 0;

// Global benchmark stats (atomic for thread-safe accumulation)
unsigned long long total_bytes_written = 0;	// Total bytes written by all threads
struct timeval benchmark_start;			// Benchmark start time (ms precision)
struct timeval benchmark_end;			// Benchmark end time (ms precision)

// Thread-private stats (internal only, no print)
struct thread_data {
	unsigned int seed;				// Per-thread random seed
	unsigned long long total_contention_attempts;	// Total buffer contention attempts
	unsigned long long locked_by_others;		// Buffers locked by other threads
};

// Buffer header (spinlock + owner) - resides in the same cache line for max contention
struct buffer_header {
	pthread_spinlock_t lock;			// Spinlock (64-byte aligned for cache line isolation)
	pthread_t thread_id;				// Last writing thread ID
	char padding[CACHE_LINE_SIZE - sizeof(pthread_spinlock_t) - sizeof(pthread_t)]; // Align to cache line
} __attribute__((aligned(CACHE_LINE_SIZE)));

// Work instance (per-thread params from argv)
struct work_instance {
	int thread_id;					// Numeric thread ID (0,1,2...)
	int is_shared;					// 0: private buf, 1: shared buf
	pthread_t tid;					// Pthread handle
	unsigned long long pool_size_bytes;		// Total shared pool size (LLC)
	unsigned int test_duration_sec;		// Test duration in seconds
	struct thread_data *worker_data;		// Thread-private stats
	unsigned long *worker_buffer;
};

// Initialize a single buffer (spinlock + header)
void initialize_buffer(char *buffer) {
	struct buffer_header *bh = (struct buffer_header *)buffer;
	bh->thread_id = INVALID_PTHREAD_ID;
	// Initialize spinlock for buffer contention
	if (pthread_spin_init(&bh->lock, PTHREAD_PROCESS_PRIVATE) != 0)
		err(-1, "pthread_spin_init failed for buffer %p", buffer);
	// Zero-initialize buffer data (for consistent write operations)
	memset(buffer + sizeof(struct buffer_header), 0, BUFFER_SIZE - sizeof(struct buffer_header));
}

// Initialize the SHARED buffer pool (all threads access this)
static void init_shared_buffer_pool(char *pool, unsigned long long pool_size) {
	char *p;
	for (p = pool; p < (pool + pool_size); p += BUFFER_SIZE) {
		initialize_buffer(p);	// Init each 4KB buffer in the shared pool
	}
}

// Work instance initialization
static int init(struct work_instance *wi) {
	struct thread_data *dp;

	// Allocate thread-private stats
	dp = (struct thread_data *)calloc(1, sizeof(struct thread_data));
	if (dp == NULL)
		err(1, "calloc failed for thread %d private data", wi->thread_id);
	wi->worker_data = dp;

	// Unique random seed per thread (maximize random buffer selection)
	dp->seed = wi->thread_id * time(NULL);


	if (wi->is_shared) {
		// Enforce 4KB alignment for the shared pool
		if (wi->pool_size_bytes % BUFFER_SIZE != 0) {
			warnx("Thread %d: Shared pool size %llu bytes is not 4KB-aligned", wi->thread_id, wi->pool_size_bytes);
			errx(-1, "Pool size must be multiple of %d bytes (4KB)", BUFFER_SIZE);
		}
		// Mutex guard: ONLY THE FIRST THREAD allocates the shared pool
		pthread_mutex_lock(&shared_worker_buffer_pool_mutex);
		if (shared_worker_buffer_pool == NULL) {
			// Allocate aligned memory for the shared LLC pool
			shared_worker_buffer_pool = aligned_alloc(BUFFER_SIZE, wi->pool_size_bytes);
			if (shared_worker_buffer_pool == NULL)
				err(-1, "aligned_alloc failed for shared buffer pool (size %llu)", wi->pool_size_bytes);
			// Initialize all buffers in the shared pool
			init_shared_buffer_pool(shared_worker_buffer_pool, wi->pool_size_bytes);
		}
		pthread_mutex_unlock(&shared_worker_buffer_pool_mutex);
	} else {
		wi->worker_buffer = malloc(wi->pool_size_bytes);
		if (wi->worker_buffer == NULL)
			err(-1, "aligned_alloc failed for private buffer pool (size %llu)", wi->pool_size_bytes);
		memset(wi->worker_buffer, 0, wi->pool_size_bytes);
	}
	return 0;
}

// Clean up thread-private data (memory free only)
static int cleanup(struct work_instance *wi) {
	struct thread_data *dp = wi->worker_data;
	if (dp == NULL)
		return 0;

	free(dp);
	free(wi->worker_buffer);
	wi->worker_data = NULL;
	return 0;
}

/*
// INTENSIVE buffer write (max cache line modification)
// Writes to ALL cache lines in the buffer to trigger massive RFO events
static void dirty_buffer_intensive(char *buffer) {
	// Cast buffer to cache line granularity
	char *cache_line = buffer;
	// Write to EVERY cache line in the 4KB buffer (64 cache lines total)
	for (int i = 0; i < BUFFER_SIZE / CACHE_LINE_SIZE; i++) {
		// Write a random value to each byte in the cache line (maximize write traffic)
		for (int j = 0; j < CACHE_LINE_SIZE; j++) {
			cache_line[j] = rand() % 256; // Random byte write (avoids predictable values)
		}
		// Move to next cache line
		cache_line += CACHE_LINE_SIZE;
	}
}
*/

static void dirty_buffer_intensive(char *buffer)
{
	unsigned long long *data = (unsigned long long *)buffer;
	for (int i = 0; i < BUFFER_SIZE / sizeof(unsigned long long); i++) {
		data[i] += 1; //read-modify-write, HITM
	}
}

/*
 * multiply two matrices in a naive way to emulate some cache footprint
 */
static void do_some_math(unsigned long *buf)
{
	unsigned long i, j, k;
	unsigned long *m1, *m2, *m3;

	m1 = buf;
	m2 = buf + matrix_size * matrix_size;
	m3 = buf + 2 * matrix_size * matrix_size;

	for (i = 0; i < matrix_size; i++) {
		for (j = 0; j < matrix_size; j++) {
			m3[i * matrix_size + j] = 0;

			for (k = 0; k < matrix_size; k++)
				m3[i * matrix_size + j] +=
					m1[i * matrix_size + k] *
					m2[k * matrix_size + j];
		}
	}
}

// Contend for a random buffer in the SHARED pool (core RFO logic)
static char *contend_for_buffer(struct work_instance *wi) {
	struct thread_data *dp = wi->worker_data;
	char *pool = shared_worker_buffer_pool;
	unsigned long long pool_size = wi->pool_size_bytes;

	while (1) {
		int random_val;
		int buffer_offset;
		struct buffer_header *bh;
		char *buffer;

		// Thread-safe random number (avoid global rand contention)
		random_val = rand_r(&dp->seed);
		// Non-negative offset (mod pool size)
		buffer_offset = abs(random_val) % (int)pool_size;
		// Align offset to 4KB buffer boundary
		buffer_offset &= ~(BUFFER_SIZE - 1);

		dp->total_contention_attempts++;

		// Get target buffer in the SHARED pool
		buffer = pool + buffer_offset;
		bh = (struct buffer_header *)buffer;

		// Try to acquire spinlock (NON-BLOCKING: maximize contention)
		if (pthread_spin_trylock(&bh->lock) == EBUSY) {
			dp->locked_by_others++;
			continue; // Retry immediately (increase contention pressure)
		}

		// Lock acquired: mark current thread as the owner
		bh->thread_id = wi->tid;
		return buffer;
	}
}

// Release buffer (unlock spinlock - critical for RFO)
static void release_buffer(char *buffer) {
	struct buffer_header *bh = (struct buffer_header *)buffer;
	// Unlock spinlock (fatal error if failed)
	if (pthread_spin_unlock(&bh->lock) != 0)
		err(-1, "pthread_spin_unlock failed for buffer %p", buffer);
}

// Core RFO test logic (max cache contention)
static unsigned long long run(struct work_instance *wi) {
	unsigned long long bytes_written = 0;
	time_t start_time = time(NULL);
	int shared = wi->is_shared;
	unsigned long wr = (matrix_size*matrix_size +
			matrix_size*matrix_size*matrix_size)*sizeof(unsigned long);

	while (1) {
		char *buffer;
		time_t current_time = time(NULL);

		// Exit on test duration timeout
		if (difftime(current_time, start_time) >= wi->test_duration_sec)
			break;

		if (shared) {
			// Contend for a random buffer in the SHARED pool
			buffer = contend_for_buffer(wi);
			// Intensive write to ALL cache lines (trigger massive RFO)
			dirty_buffer_intensive(buffer);
			bytes_written += BUFFER_SIZE;
		} else {
			do_some_math(wi->worker_buffer);
			bytes_written += wr;
		}


		if (wi->is_shared)
			// Release buffer (allow other threads to contend)
			release_buffer(buffer);
	}

	return bytes_written;
}

// Thread entry point
static void *worker_thread(void *arg) {
	struct work_instance *wi = (struct work_instance *)arg;
	unsigned long long bytes_written;

	// Initialize thread and shared pool
	if (init(wi) != 0) {
		err(-1, "Thread %d initialization failed", wi->thread_id);
	}

	// Run core RFO contention logic
	bytes_written = run(wi);

	// Atomic accumulation of total written bytes (thread-safe)
	__sync_fetch_and_add(&total_bytes_written, bytes_written);

	// Clean up thread-private data
	cleanup(wi);
	return (void *)bytes_written;
}

// Print benchmark results (simplified output + B/s precision)
static void print_benchmark_stats(int num_threads, unsigned long long pool_size_kb, unsigned int test_duration_sec) {
	// Calculate elapsed time (seconds, ms precision)
	long elapsed_ms = (benchmark_end.tv_sec - benchmark_start.tv_sec) * 1000 +
					  (benchmark_end.tv_usec - benchmark_start.tv_usec) / 1000;
	double elapsed_sec = (double)elapsed_ms / 1000.0;

	// Calculate total written data in different units
	double total_gb = (double)total_bytes_written / (1024 * 1024 * 1024);
	double total_mb = (double)total_bytes_written / (1024 * 1024);
	
	// Calculate throughput in GB/s, MB/s, and B/s (exact integer for B/s)
	double throughput_gbs = total_gb / elapsed_sec;
	double throughput_mbs = total_mb / elapsed_sec;
	unsigned long long throughput_bs = (unsigned long long)(total_bytes_written / elapsed_sec); // Exact B/s

	// Print simplified formatted results
	printf("\n=== RFO Cache Contention Benchmark Results ===\n");
	printf("Configuration:\n");
	printf("  Thread Count:          %d\n", num_threads);
	printf("Results:\n");
	printf("  Actual Elapsed Time:   %.2f s (%.0f ms)\n", elapsed_sec, (double)elapsed_ms);
	printf("  Total Bytes Written:   %llu B (%.2f GB / %.2f MB)\n", total_bytes_written, total_gb, total_mb);
	printf("  Throughput:            %.2f GB/s | %.2f MB/s | %llu B/s\n", throughput_gbs, throughput_mbs, throughput_bs);
	printf("===============================================\n\n");
}

// Print usage help (invalid arguments)
static void show_usage(const char *prog_name) {
	fprintf(stderr, "\nUsage: %s <THREAD_COUNT> <SHARED_POOL_KB> <TEST_DURATION_SEC>\n", prog_name);
	fprintf(stderr, "Arguments:\n");
	fprintf(stderr, "  THREAD_COUNT:          Number of contending threads (integer > 0)\n");
	fprintf(stderr, "  SHARED_POOL_KB:        Size of SHARED buffer pool (KB, multiple of 4)\n");
	fprintf(stderr, "  TEST_DURATION_SEC:     Test duration in seconds (integer > 0)\n");
	fprintf(stderr, "Example:\n");
	fprintf(stderr, "  %s 8 20480 10 0   # 8 threads, 20480 KB buffer, 10 second test, private buffer\n\n", prog_name);
	exit(EXIT_FAILURE);
}

// Validate positive integer arguments
static int is_positive_int(const char *str) {
	if (str == NULL || *str == '\0')
		return 0;
	for (int i = 0; str[i] != '\0'; i++) {
		if (str[i] < '0' || str[i] > '9')
			return 0;
	}
	return atoi(str) > 0;
}

// Main: argument parsing + benchmark execution
int main(int argc, char *argv[]) {
	int num_threads;
	unsigned long long pool_size_kb;
	unsigned long long pool_size_bytes;
	unsigned int test_duration_sec;
	struct work_instance *workers = NULL;
	int i, is_shared;
	void *ret;

	// Check argument count (4 required)
	if (argc != 5) {
		fprintf(stderr, "Error: Invalid arguments (expected 4, got %d)\n", argc - 1);
		show_usage(argv[0]);
	}

	// Parse and validate thread count
	if (!is_positive_int(argv[1])) {
		fprintf(stderr, "Error: Thread count must be a positive integer\n");
		show_usage(argv[0]);
	}
	num_threads = atoi(argv[1]);

	// Parse and validate shared pool size (KB, multiple of 4)
	if (!is_positive_int(argv[2])) {
		fprintf(stderr, "Error: Shared pool size (KB) must be a positive integer\n");
		show_usage(argv[0]);
	}
	pool_size_kb = strtoull(argv[2], NULL, 10);
	if (pool_size_kb % 4 != 0) {
		fprintf(stderr, "Error: Shared pool size (KB) must be a multiple of 4 (4KB alignment)\n");
		show_usage(argv[0]);
	}
	pool_size_bytes = pool_size_kb * 1024;

	// Parse and validate test duration
	if (!is_positive_int(argv[3])) {
		fprintf(stderr, "Error: Test duration must be a positive integer\n");
		show_usage(argv[0]);
	}
	test_duration_sec = atoi(argv[3]);

	// Parse and validate shared or private indicator
	//0: private, 1: share
	is_shared = atoi(argv[4]);
	if (!is_shared)
		matrix_size = sqrt(pool_size_bytes / 3 / sizeof(unsigned long));

	// Allocate work instances
	workers = calloc(num_threads, sizeof(struct work_instance));
	if (workers == NULL)
		err(-1, "calloc failed for work instances");

	// Initialize work instances with user params
	for (i = 0; i < num_threads; i++) {
		workers[i].thread_id = i;
		workers[i].pool_size_bytes = pool_size_bytes;
		workers[i].test_duration_sec = test_duration_sec;
		workers[i].is_shared = is_shared;
	}

	// Start benchmark timer
	gettimeofday(&benchmark_start, NULL);
	printf("Starting RFO Cache Contention Benchmark...\n");
	printf("Parameters: %d threads | %llu KB %s pool | %u second duration\n",
		   num_threads, pool_size_kb, is_shared ? "shared" : "private",
		   test_duration_sec);

	// Create threads (NO CPU AFFINITY - OS free scheduling)
	for (i = 0; i < num_threads; i++) {
		if (pthread_create(&workers[i].tid, NULL, worker_thread, &workers[i]) != 0) {
			err(-1, "pthread_create failed for thread %d", i);
		}
	}

	// Wait for all threads to complete
	for (i = 0; i < num_threads; i++) {
		if (pthread_join(workers[i].tid, &ret) != 0) {
			warnx("pthread_join failed for thread %d", i);
			continue;
		}
	}

	// Stop benchmark timer
	gettimeofday(&benchmark_end, NULL);

	// Print simplified results with B/s throughput
	print_benchmark_stats(num_threads, pool_size_kb, test_duration_sec);

	// Clean up shared resources
	if (shared_worker_buffer_pool != NULL) {
		free(shared_worker_buffer_pool);
		shared_worker_buffer_pool = NULL;
	}
	free(workers);
	pthread_mutex_destroy(&shared_worker_buffer_pool_mutex);

	return EXIT_SUCCESS;
}
