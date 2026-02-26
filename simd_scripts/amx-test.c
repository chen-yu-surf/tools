// SPDX-License-Identifier: GPL-2.0-only
/*
 * Author: Chen Yu <yu.c.chen@intel.com>
 *
 * gcc -O3 -march=native -fno-strict-aliasing amx-test.c -o amx-test -lpthread
 *
 * The matrix register file comprises eight tiles (named TMM0…TMM7), each having a maximum
 * size of 16 rows by 64-byte columns for a total size of 1 KiB/register and 8 KiB for the
 * entire register file. Through a tile control register (TILECFG), a programmer is able to
 * configure the size of those tiles (in terms of rows and bytes_per_row).
 */
#define _GNU_SOURCE
#include <stdio.h>		/* printf(3) */
#include <stdlib.h>		/* random(3) */
#include <sched.h>		/* CPU_SET */
#include <immintrin.h>
#include <stdint.h>
#include <unistd.h>
#include <stdbool.h>
#include <time.h>
#include <getopt.h>
#include <pthread.h>
#include <err.h>
#include <sys/syscall.h>
#include <string.h>
#include <math.h>

/* each TMM0...TMM7 is 16 rows * 64 bytes = 1024 bytes */
#define MAX_ROWS 16
#define MAX_COLS 64
#define NR_TILE 8
#define MAX_TILE_SIZE (MAX_ROWS * MAX_COLS)
#define TOTAL_MAX_TILE_SIZE (MAX_TILE_SIZE * NR_TILE)

#define STRIDE 64
#define ARCH_GET_XCOMP_PERM     0x1022
#define ARCH_REQ_XCOMP_PERM     0x1023
#define XFEATURE_XTILECFG       17
#define XFEATURE_XTILEDATA      18

#define ITERATIONS 256

#define DEFAULT_TILE_INT8_VAL 2
#define DEFAULT_TILE_INT32_VAL 0
#define DEFAULT_TILE_BF16_VAL 1.23f

/* define tile config data structure */
typedef struct __tile_config {
	uint8_t palette_id;
	uint8_t start_row;
	uint8_t reserved_0[14];
	uint16_t colsb[16];
	uint8_t rows[16];
} __tilecfg;

struct thread_data {
	char *buf;
	int id;
	pthread_t tid;
};

static pthread_mutex_t checkin_mutex;
static pthread_cond_t checkin_cv = PTHREAD_COND_INITIALIZER;
static int thread_checkedin_nr;
static int amx_ins = 0, thread_nr = 1, duration_sec = 1, nr_chunk = 1, verbose = 0;

#undef pr_fmt
#define pr_fmt(fmt)     "amx: " fmt
#define pr_info(fmt, ...) 			\
do {						\
	if (verbose)				\
		printf(pr_fmt(fmt), ##__VA_ARGS__); \
} while (0)

static uint32_t get_random(void)
{
	uint32_t random_val = 0;
	FILE *fp = fopen("/dev/random", "r");
	size_t num = 0;

	if (fp) {
		num = fread((void *)&random_val, sizeof(random_val), 1, fp);
		fclose(fp);
	}

	if (num >= 1)
		return random_val;
	else
		return 1;
}

/* Initialize tile config */
static void init_tile_config(__tilecfg *tileinfo)
{
	int i, j;
	tileinfo->palette_id = 1;
	tileinfo->start_row = 0;

	/*
	 * Initialize all the tiles and saturate them.
	 * Every 3 tiles are in 1 group that:
	 *
	 * tile[0] = tile[1] * tile[2]
	 * tile[3] = tile[4] * tile[5]
	 * tile[6] = tile[7] * tile[0]
	 *
	 * All tiles have the same MAX_ROWS * MAX_COLS.
	 */
	for (i = 0; i < NR_TILE; i++) {
		tileinfo->colsb[i] = MAX_COLS;
		tileinfo->rows[i] =  MAX_ROWS;
	}

	_tile_loadconfig(tileinfo);
}

static bool set_tiledata_use()
{
	if (syscall(SYS_arch_prctl, ARCH_REQ_XCOMP_PERM, XFEATURE_XTILEDATA)) {
		pr_info("\n Fail to do XFEATURE_XTILEDATA \n\n");
		return false;
	} else {
		return true;
	}

	return true;
}


static inline void cpuid(uint32_t *eax, uint32_t *ebx, uint32_t *ecx, uint32_t *edx)
{
	asm volatile("cpuid;"
		     : "=a" (*eax), "=b" (*ebx), "=c" (*ecx), "=d" (*edx)
		     : "0" (*eax), "2" (*ecx));
}

static __attribute__((noinline)) unsigned long long rdtsc(void)
{
	unsigned hi, lo;
	__asm__ __volatile__ ("rdtsc" : "=a"(lo), "=d"(hi));
	return ( (unsigned long long)lo)|( ((unsigned long long)hi)<<32 );
}

int nop_per_loop = 10000000;

static void nop_loop(void)
{
	int i = 0;

	while(i++ < nop_per_loop);
}

/*
 *    output  = input_x * input_y
 *    tile[0] = tile[1] * tile[2]
 *    tile[3] = tile[4] * tile[5]
 *    tile[6] = tile[7] * tile[0]
 *
 * [tile0][tile1]    ...     [tile7]
 * |<-----1 chunk: 8k------------->|
 */

#define load_and_multiply(start, in_x, in_y, out)		\
do {								\
	int8_t *input_x;					\
	int8_t *input_y;					\
	int32_t *output;					\
	output = (int32_t *)(start + out * MAX_TILE_SIZE);	\
	input_x = (int8_t *)(start + in_x * MAX_TILE_SIZE);	\
	input_y = (int8_t *)(start + in_y * MAX_TILE_SIZE);	\
	_tile_loadd(out, output, STRIDE);			\
	_tile_loadd(in_x, input_x, STRIDE);			\
	_tile_loadd(in_y, input_y, STRIDE);			\
	/* Compute dot-product of bytes in tiles. */		\
	_tile_dpbssd(out, in_x, in_y);				\
	/* Store the tile data to memory. */			\
	_tile_stored(out, output, STRIDE);			\
} while (0)

/* dpbssd dst_tile, src_tile1, src_tile2 */
static void dpbssd(struct thread_data *td)
{
	int t, k;

	for (t = 0; t < ITERATIONS; t++) {
		for (k = 0; k < nr_chunk; k++) {
			/* each trunk has 8 tiles, 8k bytes */
			char *start = (char *)td->buf + k * TOTAL_MAX_TILE_SIZE;

			/*
			 * output  = input_x * input_y
			 * tile[0] = tile[1] * tile[2]
			 * tile[3] = tile[4] * tile[5]
			 * tile[6] = tile[7] * tile[0]
			 */
			load_and_multiply(start, 0, 1, 2);
			load_and_multiply(start, 3, 4, 5);
			load_and_multiply(start, 6, 7, 0);
		}
	}
}

static void run_amx(int type, struct thread_data *td)
{
	if (type == 0) {
		nop_loop();
	} else if (type == 1) {
		dpbssd(td);
	} else
		exit(1);
}

char *progname;

static void help(void)
{
	fprintf(stderr,
		"usage: %s [OPTIONS]\n"
		"%s runs amx stress test\n"
		"  -d, --duration\n"
		"  -t, --thread-count\n"
		"  -l, --nop-per-loop\n"
		"  -s, --buffer-size-bytes\n"
		"      [Please check your L2/LLC cache size to saturate.]\n"
		"  -v, --verbose\n"
		"  -i, --instruction-type [0:nop_loop 1:dpbssd]\n", progname, progname);
}

static char* instruction_desc[] = {
	"nop_loop",
	"dpbssd",
};

char *option_string = "d:t:l:i:s:vh";
static struct option long_options[] = {
	{"duration", required_argument, 0, 'd'},
	{"thread-count", required_argument, 0, 't'},
	{"nop-per-loop", required_argument, 0, 'l'},
	{"instruction-type", required_argument, 0, 'i'},
	{"buffer-bytes", required_argument, 0, 's'},
	{"verbose", no_argument, 0, 'v'},
	{"help", no_argument, 0, 'h'},
	{0, 0, 0, 0}
};

static void parse_options(int ac, char **av)
{
	long buffer_size = TOTAL_MAX_TILE_SIZE;
	int c;

	progname = av[0];

	if (ac == 1) {
		help();
		exit(0);
	}

	while (1) {
		int option_index = 0;

		c = getopt_long(ac, av, option_string,
				long_options, &option_index);
		if (c == -1)
			break;
		switch(c) {
		case 'd':
			duration_sec = atoi(optarg);
			pr_info("Running %d seconds...\n", duration_sec);
			break;
		case 't':
			thread_nr = atoi(optarg);
			pr_info("Launching %d threads...\n", thread_nr);
			break;
		case 'i':
			amx_ins = atoi(optarg);
			pr_info("Instruction type %d...\n", amx_ins);
			break;
		case 'l':
			nop_per_loop = atoi(optarg);
			pr_info("Nop per noop set to %d...\n", nop_per_loop);
			break;
		case 's':
			buffer_size = atol(optarg);
			nr_chunk = buffer_size / TOTAL_MAX_TILE_SIZE;
			if (!nr_chunk)
				nr_chunk = 1;
			pr_info("Buffer size %ld bytes, %d groups of tiles, each group has 8 tiles...\n",
				buffer_size, nr_chunk);
			break;
		case 'v':
			verbose = 1;
			break;
		case 'h':
			help();
			exit(0);
		default:
			break;
		}
	}
}

/*
 * init_int8_tile() - Init buffer.
 * @ptr: The buffer for saving data.
 * @rows: Row number of the matrix.
 * @colsb: Column number in byte of the matrix.
 *
 */
static void init_int8_tile(char *buf)
{
	int i, j, k;
	for (k = 0; k < nr_chunk; k++) {
		buf = buf + MAX_TILE_SIZE;
		for (i = 0; i < MAX_ROWS; i++)
			for (j = 0; j < MAX_COLS; j++)
				buf[i * MAX_COLS + j] = get_random() + i + j;
	}
}

void init_amx(struct thread_data *td)
{
	__tilecfg tile_data = {0};

	/* Request permission to linux kernel to run AMX */
	if (!set_tiledata_use())
		exit(-1);

	/* Load tile configuration */
	init_tile_config(&tile_data);

	pr_info("Fault-in the buffer...\n");

	init_int8_tile(td->buf);
}

int exit_amx(void)
{
	/*
	 * Release the tile configuration to return to the init state,
	 * which releases all storage it currently holds.
	 */
	_tile_release();
}

static void worker_barrier(void)
{
        bool is_last = false;

        pthread_mutex_lock(&checkin_mutex);

        thread_checkedin_nr += 1;
        if (thread_checkedin_nr == thread_nr)
                is_last = true;

        pthread_mutex_unlock(&checkin_mutex);

        if (is_last) {
                pthread_cond_broadcast(&checkin_cv);
        } else {
                /* wait for all workers to checkin */
                pthread_mutex_lock(&checkin_mutex);
                while (thread_checkedin_nr < thread_nr)
                        if (pthread_cond_wait(&checkin_cv, &checkin_mutex))
                                err(1, "cond_wait: checkin_cv");
                pthread_mutex_unlock(&checkin_mutex);
        }
}

void *worker_thread(void *arg)
{
	int64_t start;
	unsigned long long now;
	struct thread_data *td = (struct thread_data *)arg;

	pr_info("Create thread %d, initialize amx configs...\n",
		td->id);

	init_amx(td);

	pr_info("Waiting for other worker threads to start...\n");
	worker_barrier();

	pr_info("Start running with %d seconds of instruction:%s\n",
		duration_sec, instruction_desc[amx_ins]);
	start = now = time(NULL);
	while(now < start + 1 + duration_sec) {
		run_amx(amx_ins, td);
		now = time(NULL);
	}
	printf("Throughput thread%d: %lld bytes per second\n",
		td->id, (nr_chunk * TOTAL_MAX_TILE_SIZE / (now - start)));

	exit_amx();

	return NULL;
}

int alloc_thread_data(struct thread_data *td)
{
	int i, j;
	int8_t *p;

	/* 1 chunk = 8 TILE/TMM registers, total 8k bytes per chunk */
	p = calloc(nr_chunk, TOTAL_MAX_TILE_SIZE);
	if (!p)
		exit(1);

	td->buf = p;

	return 0;
}

int main(int argc, char *argv[])
{
	struct thread_data *td, *this_td;
	int i, ret;

	parse_options(argc, argv);

	td = calloc(thread_nr, sizeof(struct thread_data));
	if (!td)
		exit(1);

	/* launch the test */
	for (i = 0; i < thread_nr; i++) {
		pthread_t tid;
		this_td = td + i;
		alloc_thread_data(this_td);
		ret = pthread_create(&tid, NULL, worker_thread,
				     this_td);
		if (ret) {
			fprintf(stderr, "error %d from pthread_create\n", ret);
			exit(1);
		}

		this_td->id = i;
		this_td->tid = tid;
	}

	for (i = 0; i < thread_nr; i++) {
		this_td = td + i;
		pthread_join(this_td->tid, NULL);
	}

	return 0;
}
