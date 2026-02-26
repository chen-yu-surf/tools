#!/bin/bash

#./hackbench.sh
#./stream.sh
#./schbench.sh
#./stress-ng.sh
#./netperf.sh

#exit

rm -rf all_result_compare.txt
echo "Start hackbench thread pipes" >> all_result_compare.txt
./bin/compare-mmtests.pl --directory work/log --benchmark hackbench-thread-pipes --names bs-hb,sc-hb >> all_result_compare.txt
echo "End hackbench thread pipes" >> all_result_compare.txt

echo >> all_result_compare.txt

echo "Start hackbench thread sockets" >> all_result_compare.txt
./bin/compare-mmtests.pl --directory work/log --benchmark hackbench-thread-sockets --names bs-hb,sc-hb >> all_result_compare.txt
echo "End hackbench thread sockets" >> all_result_compare.txt

echo >> all_result_compare.txt

echo "Start stream" >> all_result_compare.txt
./bin/compare-mmtests.pl --directory work/log --benchmark stream --name bs-st,sc-st >> all_result_compare.txt
echo "End stream" >> all_result_compare.txt

echo >> all_result_compare.txt

echo "Start stress-ng fork" >> all_result_compare.txt
./bin/compare-mmtests.pl --directory work/log --benchmark stressng --names bs-ng-fok,sc-ng-fok >> all_result_compare.txt
echo "End stress-ng fork" >> all_result_compare.txt

echo >> all_result_compare.txt

echo "Start stress-ng ctx" >> all_result_compare.txt
./bin/compare-mmtests.pl --directory work/log --benchmark stressng --names bs-ng-ctx,sc-ng-ctx >> all_result_compare.txt
echo "End stress-ng ctx" >> all_result_compare.txt

echo >> all_result_compare.txt

echo "Start stress-ng mmp" >> all_result_compare.txt
./bin/compare-mmtests.pl --directory work/log --benchmark stressng --names bs-ng-mmp,sc-ng-mmp >> all_result_compare.txt
echo "End stress-ng mmp" >> all_result_compare.txt

echo >> all_result_compare.txt

echo "Start netperf" >> all_result_compare.txt
N=(32 64 96 128 160 192 224 256)
for Npairs in "${N[@]}"; do
	echo " start netperf-${Npairs}pairs" >> all_result_compare.txt
	./bin/compare-mmtests.pl --directory work/log --benchmark netperf-ipv4-tcp-rr --names "bs-np-${Npairs}pairs,sc-np-${Npairs}pairs" >>all_result_compare.txt
	echo " end netperf-${Npairs}pairs" >> all_result_compare.txt
	echo
done
echo "End netperf" >> all_result_compare.txt

echo >> all_result_compare.txt

echo "Start schbench" >> all_result_compare.txt
cd schbench_new_parser
rm -rf amd
mkdir amd
cp -r ../work/log/bs-sb/ ./amd
cp -r ../work/log/sc-sb/ ./amd
./start_parse.sh
cat compare_final.log >> ../all_result_compare.txt
cd ..
echo "End schbench" >> all_result_compare.txt
