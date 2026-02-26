// C Program to demonstrate
// use of nanosleep
#include <stdio.h>
#include <time.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	int response, sleep_ns = 1000;
	struct timespec remaining, request = { 0, 100 };

	if (argc != 2) {
		printf("please specify the sleep nanosleep\n");
		return -1;
	}
	sleep_ns = atoi(argv[1]);

	while (1) {
		request.tv_sec = 0;
		request.tv_nsec = sleep_ns;
		response = nanosleep(&request, &remaining);
	}
	return 0;
}
