rm -rf *.txt

#1v1
#hackbench
python3 extract_hackbench.py hb_1snconline_n0_1v1/iter-0/hackbench-process-pipes/logs/ > hackbench_1snconline_n0.txt
python3 extract_hackbench.py hb_1vponline_v0_1v1/iter-0/hackbench-process-pipes/logs/ > hackbench_1vponline_v0.txt

#kernbench
python3 extract_kernbench.py kb_1snconline_n0_1v1/iter-0/kernbench/logs > kernbench_1snconline_n0.txt
python3 extract_kernbench.py kb_1vponline_v0_1v1/iter-0/kernbench/logs > kernbench_1vponline_v0.txt

#stressng-mmap
python3 extract_stressng-mmap.py st_1snconline_n0_1v1/iter-0/stressng/logs > stressngmmap_1snconline_n0.txt
python3 extract_stressng-mmap.py st_1vponline_v0_1v1/iter-0/stressng/logs > stressngmmap_1vponline_v0.txt

#3v3
#hackbench
python3 extract_hackbench.py hb_3vponline_v0_3v3/iter-0/hackbench-process-pipes/logs/ > hackbench_3vponline_v0.txt
python3 extract_hackbench.py hb_3snconline_n0_3v3/iter-0/hackbench-process-pipes/logs/ > hackbench_3snconline_n0.txt

python3 extract_hackbench.py hb_3vponline_v1_3v3/iter-0/hackbench-process-pipes/logs/ > hackbench_3vponline_v1.txt
python3 extract_hackbench.py hb_3snconline_n1_3v3/iter-0/hackbench-process-pipes/logs/ > hackbench_3snconline_n1.txt

python3 extract_hackbench.py hb_3vponline_v2_3v3/iter-0/hackbench-process-pipes/logs/ > hackbench_3vponline_v2.txt
python3 extract_hackbench.py hb_3snconline_n2_3v3/iter-0/hackbench-process-pipes/logs/ > hackbench_3snconline_n2.txt

#kernbench
python3 extract_kernbench.py kb_3vponline_v0_3v3/iter-0/kernbench/logs > kernbench_3vponline_v0.txt
python3 extract_kernbench.py kb_3snconline_n0_3v3/iter-0/kernbench/logs > kernbench_3snconline_n0.txt

python3 extract_kernbench.py kb_3vponline_v1_3v3/iter-0/kernbench/logs > kernbench_3vponline_v1.txt
python3 extract_kernbench.py kb_3snconline_n1_3v3/iter-0/kernbench/logs > kernbench_3snconline_n1.txt

python3 extract_kernbench.py kb_3vponline_v2_3v3/iter-0/kernbench/logs > kernbench_3vponline_v2.txt
python3 extract_kernbench.py kb_3snconline_n2_3v3/iter-0/kernbench/logs > kernbench_3snconline_n2.txt

#redis
python3 extract_redis.py mr_3snconline_n0_3v3/iter-0/redis/logs > redis_3snconline_n0.txt
python3 extract_redis.py mr_3vponline_v0_3v3/iter-0/redis/logs > redis_3vponline_v0.txt

python3 extract_redis.py mr_3snconline_n1_3v3/iter-0/redis/logs > redis_3snconline_n1.txt
python3 extract_redis.py mr_3vponline_v1_3v3/iter-0/redis/logs > redis_3vponline_v1.txt

python3 extract_redis.py mr_3snconline_n2_3v3/iter-0/redis/logs > redis_3snconline_n2.txt
python3 extract_redis.py mr_3vponline_v2_3v3/iter-0/redis/logs > redis_3vponline_v2.txt
