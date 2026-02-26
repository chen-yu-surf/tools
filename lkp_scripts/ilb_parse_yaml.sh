grep -r -n "test:" aim7 | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > aim7_subtest.log
grep -r -n "tbox_group:" aim7 | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > aim7_tbox.log

grep -r -n "test:" aim9 | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > aim9_subtest.log
grep -r -n "tbox_group:" aim9 | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > aim9_tbox.log

grep -r -n "nr_threads:" dbench | awk -F ' ' '{print $2}' | sort -n  | awk '!seen[$0]++'  > dbench_nr.log
grep -r -n "tbox_group:" dbench | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > dbench_tbox.log

grep -r -n "nr_threads:" hackbench | awk -F ' ' '{print $2}' | sort -n  | awk '!seen[$0]++'  > hackbench_nr.log
grep -r -n "mode:"  hackbench | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > hackbench_mode.log
grep -r -n "ipc:" hackbench | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > hackbench_ipc.log
grep -r -n "tbox_group:" hackbench | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > hackbench_tbox.log


grep -r -n "tbox_group:" kernbench | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > kernbench_tbox.log

grep -r -n "nr_threads:" netperf | awk -F ' ' '{print $2}' | sort -n  | awk '!seen[$0]++'  > netperf_nr.log
grep -r -n "test:" netperf | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > netperf_subtest.log
grep -r -n "tbox_group:" netperf | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > netperf_tbox.log

grep -r -n "message_threads:" schbench | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > schbench_message.log
grep -r -n "worker_threads:" schbench | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > schbench_worker.log
grep -r -n "tbox_group:" schbench | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > schbench_tbox.log


grep -r -n "nr_threads:" stress-ng | awk -F ' ' '{print $2}' | sort -n  | awk '!seen[$0]++'  > stress-ng_nr.log
grep -r -n "class:" stress-ng | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > stress-ng_class.log
grep -r -n "test:" stress-ng | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > stress-ng_subtest.log
grep -r -n "tbox_group:" stress-ng | awk -F ' ' '{print $2}' | sort -n | awk '!seen[$0]++'  > stress-ng_tbox.log

grep -r -n "nr_threads:" tbench | awk -F ' ' '{print $2}' | sort -n  | awk '!seen[$0]++'  > tbench_nr.log
grep -r -n "tbox_group:" tbench | awk -F ' ' '{print $3}' | sort -n  | awk '!seen[$0]++'  > tbench_tbox.log
