#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

void* thread_func(void* arg) {
    while(1);
    return NULL;
}

int main(int argc, char* argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <nr>\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    int nr = atoi(argv[1]);
    if (nr <= 0) {
        fprintf(stderr, "nr must be a positive integer\n");
        exit(EXIT_FAILURE);
    }

    pthread_t* threads = malloc(nr * sizeof(pthread_t));
    if (threads == NULL) {
        perror("malloc failed");
        exit(EXIT_FAILURE);
    }

    for (int i = 0; i < nr; i++) {
        if (pthread_create(&threads[i], NULL, thread_func, NULL) != 0) {
            perror("pthread_create failed");
            exit(EXIT_FAILURE);
        }
    }

    for (int i = 0; i < nr; i++) {
        pthread_join(threads[i], NULL);
    }

    free(threads);
    return 0;
}
