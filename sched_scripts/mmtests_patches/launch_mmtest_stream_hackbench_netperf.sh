#stream
file_path="shellpack_src/src/stream/stream-bench"
# the stream-bench needs to append "STREAM_ARRAY_ELEMENTS=STREAM_SIZE"
sed -i "s/STREAM_ARRAY_ELEMENTS=STREAM_SIZE/STREAM_ARRAY_ELEMENTS=128000000/g" "$file_path"
./run-mmtests.sh --no-monitor --config config-stream baseline_2G
sed -i "s/STREAM_ARRAY_ELEMENTS=128000000/STREAM_ARRAY_ELEMENTS=STREAM_SIZE/g" "$file_path"

sed -i "s/STREAM_ARRAY_ELEMENTS=STREAM_SIZE/STREAM_ARRAY_ELEMENTS=22369621/g" "$file_path"
./run-mmtests.sh --no-monitor --config config-stream baseline_512M
sed -i "s/STREAM_ARRAY_ELEMENTS=22369621/STREAM_ARRAY_ELEMENTS=STREAM_SIZE/g" "$file_path"

#hackbench
file_path="shellpack_src/src/hackbench/hackbench-bench"

# the hackbench-bench needs to append "NR_THREADS=MYTHREADS"
for i in 1 2 3 4 5 6; do
	sed -i "s/NR_THREADS=MYTHREADS/NR_THREADS=$i/g" "$file_path"
	./run-mmtests.sh --no-monitor --config config-scheduler-hackbench baseline-fd$i
	sync
	sleep 5
	sed -i "s/NR_THREADS=$i/NR_THREADS=MYTHREADS/g" "$file_path"
done

#netperf
# need to add the following CFLAGS
# export CFLAGS+=" -DWANT_UNIX -D_GNU_SOURCE"
