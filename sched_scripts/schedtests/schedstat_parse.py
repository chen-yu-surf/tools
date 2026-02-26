#!/usr/bin/python3

#SIS Search Efficiency: A ratio expressed as a percentage of runqueues
#scanned versus idle CPUs found. A 100% efficiency indicates that
#the target, prev or recent CPU of a task was idle at wakeup. The
#lower the efficiency, the more runqueues were scanned before an
#idle CPU was found.

#SIS Domain Search Efficiency: Similar, except only for the slower SIS
#patch.

#SIS Fast Success Rate: Percentage of SIS that used target, prev or
#recent CPUs.

#SIS Success rate: Percentage of scans that found an idle CPU.

#cpuX %u 0 %u %u %u %u %llu %llu %lu %u %u %u %u %u %u %u %u %u
#cpu223 1578710 0 1966930 185544 193122 34953 16155881242 2335835983 204436 171062 17833 469870 8324
#s1:rq->yld_count,s2:0,s3:rq->sched_count,s4:rq->sched_goidle,s5:rq->ttwu_count,s6:rq->ttwu_local
#s7:rq->rq_cpu_time,s8:rq->rq_sched_info.run_delay,s9:rq->rq_sched_info.pcount
#s10:rq->sis_search,s11:rq->sis_domain_search,s12:rq->sis_scanned, s13:rq->sis_failed

#For example, after running the schedtests, we can get the schedstats via
#./report -t netperf -b 5.16.0-rc3-stat+ -s 10,11,12,13 > netperf_result.log
#then calculate the metrics using this script:
#schedstat_parse.py -f netperf_result.log

#Link: https://lore.kernel.org/lkml/20210726102247.21437-2-mgorman@techsingularity.net

import os
import sys
import getopt
import numpy as np
import pandas as pd

def usage():
    print("./schedstat_parse.py -f file")
    print("\t-f (--file) schedfile")

if __name__ == "__main__":

    try:
        opts, args = getopt.getopt(sys.argv[1:], '-h-f:',
                        ['help','file='])
    except getopt.GetoptError:
        usage()
        # 128 - invalid argument to exit
        sys.exit(128)

    baseline = ""

    for opt_name, opt_value in opts:
        if opt_name in ('-h', '--help'):
            usage()
            sys.exit()
        if opt_name in ('-f', '--file'):
            filename = opt_value

    if not filename:
        usage()
        # catchall for general errors
        sys.exit(1)

    curr_path = os.getcwd()
    logfile = os.path.join(curr_path, filename)

    fd = open(logfile, 'r')
    stat = np.zeros((20,1))
    begin = 0

    for line in fd.readlines():
        items = line.strip().split()
        if items == []:
            # search for next benchmark section
            begin = 0
            print()
            continue
        if items[0] == "case":
            begin = 1
            print("%12s\t%12s\t%12s\t%12s\t%12s\t%12s\t%12s\t%12s" % (items[0], items[1], items[2], "se_eff%", "dom_eff%", "fast_rate%", "success_rate%", "util_avg%"))
            continue
        if begin != 1:
            continue
        sis_search = int(items[5])
        sis_domain_search = int(items[6])
        sis_scanned = int(items[7])
        sis_failed = int(items[8])

        util_avg = int(items[9]) / 114688

        idle_found = sis_search - sis_failed
        sis_search_eff = idle_found / sis_scanned

        idle_fast_found = sis_search - sis_domain_search
        sis_domain_scanned = sis_scanned - idle_fast_found
        idle_domain_found = sis_domain_search - sis_failed
        sis_domain_search_eff = idle_domain_found / sis_domain_scanned

        sis_fast_success_rate = idle_fast_found / sis_search
        sis_success_rate = idle_found / sis_search

        print("%12s\t%12s\t%12s\t%12.3f\t%12.3f\t%12.3f\t%12.3f\t%12.3f" % (items[0], items[1], items[2], 100*sis_search_eff, 100*sis_domain_search_eff, 100*sis_fast_success_rate, 100*sis_success_rate, 100*util_avg))
