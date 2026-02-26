#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>

#define THREAD_COUNT 16

unsigned long fibonacci(int n) {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

volatile int exit_flag[THREAD_COUNT] = {0};

void* thread_func(void* arg) {
    int thread_id = *(int*)arg;
    char thread_name[16];

    snprintf(thread_name, sizeof(thread_name), "yogini_%d", thread_id);
    pthread_setname_np(pthread_self(), thread_name);
    printf("Thread %d started.\n", thread_id);

    while (!exit_flag[thread_id - 1]) {
        unsigned long result = fibonacci(35);
    }

    printf("Thread %d exiting.\n", thread_id);
    pthread_exit(NULL);
}

int main() {
    pthread_t threads[THREAD_COUNT];
    int thread_ids[THREAD_COUNT];

    for (int i = 0; i < THREAD_COUNT; ++i) {
        thread_ids[i] = i + 1;
        if (pthread_create(&threads[i], NULL, thread_func, &thread_ids[i])) {
            fprintf(stderr, "Error creating thread %d\n", i + 1);
            return 1;
        }
        printf("Created thread %d.\n", i + 1);
        sleep(i);
    }

    for (int i = 0; i < THREAD_COUNT; ++i) {
        exit_flag[i] = 1;
        sleep(1);
    }

    for (int i = 0; i < THREAD_COUNT; ++i) {
        pthread_join(threads[i], NULL);
    }

    printf("All threads have exited. Main thread terminating.\n");
    return 0;
}
