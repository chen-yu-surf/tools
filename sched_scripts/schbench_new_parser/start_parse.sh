
#replace with your directory provided by mmtests
RESULT_DIR_BASE="amd/baseline-sb/"
RESULT_DIR_CHANGE="amd/sc-sb/"

rm -rf *.log

for i in 0; do
	for t in 1 2 4 8 16 32 64 127; do
		python3 ./extract_schbench.py ${RESULT_DIR_BASE}"iter-"$i"/schbench/logs/schbench-"$t".log" baseline_total_thread$t.log
		python3 ./extract_schbench.py ${RESULT_DIR_CHANGE}"iter-"$i"/schbench/logs/schbench-"$t".log" change_total_thread$t.log
	done
done

for t in 1 2 4 8 16 32 64 127; do
	python3 ./calc_average.py baseline_total_thread$t.log baseline_average_thread$t.log 
	python3 ./calc_average.py change_total_thread$t.log change_average_thread$t.log 
	python3 ./check_compare.py baseline_average_thread$t.log change_average_thread$t.log > compare_thread$t.log
	echo "schbench thread = "$t >> compare_final.txt
	cat  compare_thread$t.log >> compare_final.txt
	echo "" >> compare_final.txt
done
rm -rf *.log
mv compare_final.txt compare_final.log
