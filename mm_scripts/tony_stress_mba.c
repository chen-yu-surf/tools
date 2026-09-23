#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#define SCHEMATA        "/sys/fs/resctrl/schemata"
#define GBYTE           (1L * 1024 * 1024 * 1024)
#define LARGE_BUF       (4L * GBYTE)
#define SMALL_BUF       (16L * 1024)
int main(int argc, char **argv)
{
        void *p, *large_buf, *small_buf;
        struct timeval start, finish;
        FILE *schemata;
        double delta;
        long val = 1;
        schemata = fopen(SCHEMATA, "w");
        if (!schemata) {
                perror(SCHEMATA);
                return 1;
        }
        small_buf = mmap(NULL, SMALL_BUF, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0L);
        large_buf = mmap(NULL, LARGE_BUF, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0L);
        if (small_buf == MAP_FAILED || large_buf == MAP_FAILED) {
                perror("Insufficient memory\n");
                return 1;
        }
        /* Allocate and fill */
        for (p = large_buf; p < large_buf + LARGE_BUF; p += 4096)
                *(long *)p = val++;

        for (int throttle = 1; throttle <= 100; throttle += 1) {
                printf("%d", throttle);
                fprintf(schemata, "MB_LOCAL:0=%d\n", throttle);
                if (fflush(schemata) == EOF) {
                        perror("write(" SCHEMATA ")");
                        return 1;
                }
                rewind(schemata);
                for (int iter = 0; iter < 5; iter++) {
                        gettimeofday(&start, NULL);
                        for (p = large_buf; p < large_buf + LARGE_BUF; p += SMALL_BUF)
                                memcpy(p, small_buf, SMALL_BUF);
                        gettimeofday(&finish, NULL);
                        delta = finish.tv_sec - start.tv_sec;
                        delta += (finish.tv_usec - start.tv_usec) / 1.0e6;
                        printf(",%.3f", (LARGE_BUF / delta) / GBYTE);
                        fflush(stdout);
                }
                printf("\n");
        }
        return 0;
}
