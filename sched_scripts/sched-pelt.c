#include <math.h>
#include <stdio.h>


/*
 * for a task running 8 ms in every 16 ms period,
 * run = (y^0+y^1+ ... y^7)+(y^16+y^17+ ... +y^23) + ...
 *
 */
/*
void calc_converged_test(int halflife)
{
	long last = 0, y_inv, run = 0;
	double y;
	int i = 0, idx_8ms;

	y = pow(0.5, 1/(double)halflife);
	y_inv = ((1UL<<32)-1)*y;

	for (; ; i++) {
		if (i < 0)
			break;

		idx_8ms = i / 8;
		if (idx_8ms % 2)
			continue;

		run = ((run*y_inv)>>32) + 1024;

		if (last == run)
			break;

		last = run;
	}
	printf("run 8ms every 16ms, use HALFLIFE=%dms max_load=%ld\n", halflife, run/1000);
}
*/

void calc_util_avg(int halflife, int run, int dur)
{
/*
 * util_avg_sleep = (1-y^A) / ((1-y^B)*(1-y)) * 1024
 * util_avg_wake = (1-y^A) / ((1-y^B)*(1-y)) * 1024 * y^(B-A)
 */
	unsigned long util_avg_sleep, util_avg_wake;
	double y = pow(0.5, 1/(double)halflife);
	double yA, yB, yBA;

	printf("Halflife %d, run %d ms in %d ms\n",
		halflife, run, dur);
	printf("y is %f\n", y);
	yA = pow(y, run); 
	yB = pow(y, dur);
	printf("yA is %f, yB is %f\n", yA, yB);
	yBA = pow(y, dur-run);
	 
	util_avg_sleep = (1-yA) / ((1-yB)*(1-y)) * 1024;
	util_avg_wake = (1-yA) / ((1-yB)*(1-y)) * 1024 * yBA;

	printf("sleep %ld, wake %ld\n", util_avg_sleep, util_avg_wake);
}

void calc_util_avg_diet(int halflife, int run, int dur)
{
/*
 * util_avg_sleep = (1-y^A) / (1-y^B) * 1024
 * util_avg_wake = (1-y^A) / (1-y^B) * 1024 * y^(B-A)
 */
	unsigned long util_avg_sleep, util_avg_wake;
	double y = pow(0.5, 1/(double)halflife);
	double yA, yB, yBA;

	printf("Halflife %d, run %d ms in %d ms\n",
		halflife, run, dur);
	printf("y is %f\n", y);
	yA = pow(y, run); 
	yB = pow(y, dur);
	printf("yA is %f, yB is %f\n", yA, yB);
	yBA = pow(y, dur-run);
	 
	util_avg_sleep = (1-yA) / (1-yB) * 1024;
	util_avg_wake = (1-yA) / (1-yB) * 1024 * yBA;

	printf("sleep %ld, wake %ld\n", util_avg_sleep, util_avg_wake);
}

int main(int argc, char *argv)
{
/*
	calc_converged_test(32);
	calc_converged_test(16);
	calc_converged_test(8);
*/
	//calc_util_avg(32, 8, 16);
	//calc_util_avg(16, 8, 16);
	//calc_util_avg(8, 8, 16);
	calc_util_avg_diet(32, 8, 16);
	calc_util_avg_diet(16, 8, 16);
	calc_util_avg_diet(8, 8, 16);

	return 0;
}
