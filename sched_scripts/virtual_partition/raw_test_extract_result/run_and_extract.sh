# install redis-server and redis benchmark before testings
# example:
# ./redis_run_and_extract.sh 0  (3snc run 3 redis in paralle)
# ./redis_run_and_extract.sh 1 0  (vp0 runs 1 redis)
# ./redis_run_and_extract.sh 1 1  (vp1 runs 1 redis)
# ./redis_run_and_extract.sh 1 2  (vp2 runs 1 redis)

lp=0

cpunum=(86 84 86)

# make redis happy
echo 1 > /proc/sys/vm/overcommit_memory

function run_snc_3v3()
{
	# replace port CUST_PORT to port 6379
	cp redis-memonly.conf redis-memonly0.conf
	sed -i 's/^port CUST_PORT/port 6379/' redis-memonly0.conf
	sed -i 's/^pidfile \/var\/run\/redis_CUST_PORT\.pid/pidfile \/var\/run\/redis_6379.pid/' redis-memonly0.conf
	cp redis-memonly.conf redis-memonly1.conf
	sed -i 's/^port CUST_PORT/port 6380/' redis-memonly1.conf
	sed -i 's/^pidfile \/var\/run\/redis_CUST_PORT\.pid/pidfile \/var\/run\/redis_6380.pid/' redis-memonly1.conf
	cp redis-memonly.conf redis-memonly2.conf
	sed -i 's/^port CUST_PORT/port 6381/' redis-memonly2.conf
	sed -i 's/^pidfile \/var\/run\/redis_CUST_PORT\.pid/pidfile \/var\/run\/redis_6381.pid/' redis-memonly1.conf

	pkill -9 redis

	numactl -m 0 -N 0 redis-server redis-memonly0.conf &
	numactl -m 1 -N 1 redis-server redis-memonly1.conf &
	numactl -m 2 -N 2 redis-server redis-memonly2.conf &

	sleep 7
	rm -rf *.txt
	echo "warm up"
	numactl -m 0 -N 0 redis-benchmark --csv -c 86 --threads 4 -h localhost -p 6379 -r 50000 -n 100000 -P 256 > 0.txt &
	pid1=$!

	#numactl -m 1 -N 1 redis-benchmark -h localhost -p 6380 -n 50000 -c 84 --csv > 1.txt &
	numactl -m 1 -N 1 redis-benchmark --csv -c 84 --threads 4 -h localhost -p 6380 -r 50000 -n 100000 -P 256 > 1.txt &
	pid2=$!

	#numactl -m 2 -N 2 redis-benchmark -h localhost -p 6381 -n 50000 -c 86 --csv > 2.txt &
	numactl -m 2 -N 2 redis-benchmark --csv -c 86 --threads 4 -h localhost -p 6381 -r 50000 -n 100000 -P 256 > 2.txt &
	pid3=$!
	wait $pid1 $pid2 $pid3
	echo "start to run"

	sleep 5
	for i in {1..6}; do
		echo "Starting iteration $i"

		#numactl -m 0 -N 0 redis-benchmark -h localhost -p 6379 -n 50000 -c 86 --csv > 0.txt &
		numactl -m 0 -N 0 redis-benchmark --csv -c 86 --threads 4 -h localhost -p 6379 -r 50000 -n 100000 -P 256 > 0.txt &
		pid1=$!

		#numactl -m 1 -N 1 redis-benchmark -h localhost -p 6380 -n 50000 -c 84 --csv > 1.txt &
		numactl -m 1 -N 1 redis-benchmark --csv -c 84 --threads 4 -h localhost -p 6380 -r 50000 -n 100000 -P 256 > 1.txt &
		pid2=$!

		#numactl -m 2 -N 2 redis-benchmark -h localhost -p 6381 -n 50000 -c 86 --csv > 2.txt &
		numactl -m 2 -N 2 redis-benchmark --csv -c 86 --threads 4 -h localhost -p 6381 -r 50000 -n 100000 -P 256 > 2.txt &
		pid3=$!

		wait $pid1 $pid2 $pid3

		python3 parse.py 0.txt >> snc0.txt
		python3 parse.py 1.txt >> snc1.txt
		python3 parse.py 2.txt >> snc2.txt
		echo "Finished iteration $i"
	done

	cat snc0.txt | sort -t, -k1,1 > raw_snc0.log
	cat snc1.txt | sort -t, -k1,1 > raw_snc1.log
	cat snc2.txt | sort -t, -k1,1 > raw_snc2.log

	rm -rf *.txt
}

function run_lp_3v3()
{
	pkill -9 redis

	cp redis-memonly.conf redis-memonly0.conf
	sed -i 's/^port CUST_PORT/port 6379/' redis-memonly0.conf
	sed -i 's/^pidfile \/var\/run\/redis_CUST_PORT\.pid/pidfile \/var\/run\/redis_6379.pid/' redis-memonly0.conf

	redis-server redis-memonly0.conf &
	sleep 7
	rm -rf *.txt
	echo "warm up"
	redis-benchmark --csv -c $c --threads 4 -h localhost -p 6379 -r 50000 -n 100000 -P 256 > t.txt
	echo "start to run"

	for i in {1..6}; do
		echo "Starting iteration $i"
		#redis-benchmark -h localhost -p 6379 -n 50000 -c $c --csv > t.txt
		redis-benchmark --csv -c $c --threads 4 -h localhost -p 6379 -r 50000 -n 100000 -P 256 > t.txt
		python3 parse.py t.txt >> lp$lp.txt
		echo "Finished iteration $i"
	done
	cat lp$lp.txt | sort -t, -k1,1 > raw_lp$lp.log
	rm -rf *.txt
}

if [ $# -eq 0 ]; then
	echo "Warn: no parameter is provided"
	echo "Usage: $0 snc_or_vp [vp_index]"
	echo "$0 0  (3snc run 3 redis in paralle)"
	echo "$0 1 0  (vp0 runs 1 redis)"
	echo "$0 1 1  (vp1 runs 1 redis)"
	echo "$0 1 2  (vp2 runs 1 redis)"
	exit 1
fi

case $1 in
	0)
		run_snc_3v3
        	;;
	1)
		lp=$2
		c=${cpunum[$lp]}
        	run_lp_3v3
        	;;
esac
