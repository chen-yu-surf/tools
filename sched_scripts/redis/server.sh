#!/bin/bash
#

# cpu0-cpu59, cpu120-cpu179
# node0,node1
pkill -9 redis
x=0
for j in $(seq 1 60)
do
    portp=$[16000+j]
    numactl -C $x -m 0,1 redis-server redis.conf --port ${portp} &
    let x+=1
done

x=120
for j in $(seq 61 120)
do
    portp=$[16000+j]
    numactl -C $x -m 0,1 redis-server redis.conf --port ${portp} &
    let x+=1
done   
