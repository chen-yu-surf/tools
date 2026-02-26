#!/bin/bash
#

# cpu60-cpu119, cpu180-cpu239
# node3,node4
x=60
for j in $(seq 1 60)
do
        portp=$[16000+j]
        #--threads are recommended to be consistent with the number of bound cores.
        #--clients  are number of clients per thread (default: 50), ByteDance gives 20.
        #-n is number of total requests per client (default: 10000), ByteDance gives 100000.
        # This command means that one client instance will generate 1(--threads)*20(--clients)*100000(-n) pressure to stress one server instance. If the core utilization of the server instance bound is not full, you can adjust the number of clients(--clients) and requests(-n).
        numactl -C $x -m 2,3 memtier_benchmark -s 127.0.0.1 -p ${portp} --threads=1 --clients=20 -n 100000 --data-size=32 --ratio=1:0 --out-file=./log/log_${portp} &
	let x+=1
done

x=180		#Start binding core from core0.
for j in $(seq 61 120)
do
        portp=$[16000+j]
        numactl -C $x -m 2,3 memtier_benchmark -s 127.0.0.1 -p ${portp} --threads=1 --clients=20 -n 100000 --data-size=32 --ratio=1:0 --out-file=./log/log_${portp} &
        let x+=1
done


wait
