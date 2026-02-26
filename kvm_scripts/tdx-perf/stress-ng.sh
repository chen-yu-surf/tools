#!/bin/bash

rela_path=`dirname $0`
test_path=`cd "$rela_path" && pwd`
nrcpu=`nproc --all`
install=0

install_stress()
{
	if [ -d stress-ng ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git clone https://github.com/ColinIanKing/stress-ng.git stress-ng;
	cd stress-ng;
	make clean
	make -j${nrcpu}
	cp  stress-ng /usr/bin/
	cd -
}

run_stress()
{
	stress-ng --cpu $nr_instance --timeout $duration > $test_path/PREFIX-stress.log;
	sync;
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	if [ "$install" = "1" ]; then
		install_stress
	else
		run_stress
	fi
fi
