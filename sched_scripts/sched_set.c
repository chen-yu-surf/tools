/*https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux_for_real_time/
9/html/optimizing_rhel_9_for_real_time_for_low_latency_operation/
assembly_displaying-the-priority-for-a-process_optimizing-rhel9-for-real-time-for-low-latency-operation*/

#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <linux/unistd.h>
#include <linux/kernel.h>
#include <linux/types.h>
#include <sys/syscall.h>
#include <pthread.h>

#define gettid() syscall(__NR_gettid)

#define SCHED_DEADLINE    6

/* XXX use the proper syscall numbers */
#ifdef __x86_64__
#define __NR_sched_setattr        314
#define __NR_sched_getattr        315
#endif

struct sched_attr {
	__u32 size;
	__u32 sched_policy;
	__u64 sched_flags;

	/* SCHED_NORMAL, SCHED_BATCH */
	__s32 sched_nice;

	/* SCHED_FIFO, SCHED_RR */
	__u32 sched_priority;

	/* SCHED_DEADLINE (nsec) */
	__u64 sched_runtime;
	__u64 sched_deadline;
	__u64 sched_period;
};

int sched_getattr(pid_t pid,
		  struct sched_attr *attr,
		  unsigned int size,
		  unsigned int flags)
{
	return syscall(__NR_sched_getattr, pid, attr, size, flags);
}

int sched_setattr(pid_t pid,
		  struct sched_attr *attr,
		  unsigned int flags)
{
	return syscall(__NR_sched_setattr, pid, attr, flags);
}

int main (int argc, char **argv)
{
	struct sched_attr attr;
	unsigned int flags = 0;
	int ret, pid;
	__u64 slice;

	if (argc != 3) {
		perror("please provide pid, slice\n");
		exit(-1);
	}

	pid = atoi(argv[1]);
	slice = atol(argv[2]);

	ret = sched_getattr(pid, &attr, sizeof(attr), flags);
	if (ret < 0) {
		perror("sched_getattr");
		exit(-1);
	}

	attr.sched_runtime = slice;
	ret = sched_setattr(pid, &attr, flags);
	if (ret < 0) {
		perror("sched_setattr");
		exit(-1);
	}

	/*
	printf("main thread pid=%ld\n", gettid());
	printf("main thread policy=%d\n", attr.sched_policy);
	printf("main thread nice=%d\n", attr.sched_nice);
	printf("main thread priority=%d\n", attr.sched_priority);
	printf("main thread runtime=%lld\n", attr.sched_runtime);
	printf("main thread deadline=%lld\n", attr.sched_deadline);
	printf("main thread period=%lld\n", attr.sched_period);
	*/

	return 0;
}
