#!/bin/bash

KERNEL_SRC=$1
KERNEL_CONFIG=/boot/config-$(uname -r)
QEMU_SRC=$2
QEMU_IMAGE=$3
MMTESTS_SRC=$4
NR_VCPUS=$5
DURATION=$6
nrcpu=`nproc --all`

install_kernel()
{
	if [ -d ${KERNEL_SRC} ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git clone --branch tdx_6.8-rc5-v19-hugepage https://github.com/intel-sandbox/os.linux.kernel.fyin_optimal_page $KERNEL_SRC
	cd $KERNEL_SRC
	patch -p1 < ../kselftest_tdx.diff
	cp $KERNEL_CONFIG .config
	make olddefconfig
	make all -j$nrcpu -s
	cd ..
}

install_qemu()
{
	if [ -d ${QEMU_SRC} ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git clone https://github.com/intel-sandbox/fyin.qemu-64K --branch qemu-tdx-passthru $QEMU_SRC
	cd $QEMU_SRC
	patch -p1 < ../qemu_thp_support_tdx.diff
	./configure --enable-kvm --target-list=x86_64-softmmu
	make -j$nrcpu
	cp build/qemu-system-x86_64 /usr/bin/$QEMU_IMAGE
	cp build/qemu-bundle/usr/local/share/qemu/efi-virtio.rom /usr/share/qemu/
	cp build/qemu-bundle/usr/local/share/qemu/bios-256k.bin /usr/share/qemu/
	cp build/qemu-bundle/usr/local/share/qemu/bios.bin /usr/share/qemu/
	cp build/qemu-bundle/usr/local/share/qemu/vgabios.bin /usr/share/qemu/
	# for NIC passthrough
	cp build/qemu-bundle/usr/local/share/qemu/efi-e1000e.rom /usr/share/qemu/
	cd ..

}

install_mmtests()
{
	if [ -d ${MMTESTS_SRC} ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git clone https://github.com/gormanm/mmtests.git;
	cp mmtest_fix_for_ubuntu.diff mmtests/
	cp mmtest_fix_for_netperf.diff mmtests/
	cd mmtests
	patch -p1 < mmtest_fix_for_ubuntu.diff
	sed -i "s/+NR_PAIRS=[0-9]*/+NR_PAIRS=$((NR_VCPUS / 2))/g" mmtest_fix_for_netperf.diff
	sed -i "s/\$DURATION/${DURATION}/g" mmtest_fix_for_netperf.diff
	patch -p1 < mmtest_fix_for_netperf.diff
	cd ..
	# pip install binary-search
	# perl -MCPAN -e "install List::BinarySearch"
	# apt install expect
}

install_bcc()
{
	if [ -d "bcc" ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git clone https://github.com/iovisor/bcc.git
	mkdir bcc/build; cd bcc/build
	cmake ..
	make
	sudo make install
	cmake -DPYTHON_CMD=python3 .. # build python3 binding
	pushd src/python/
	make
	sudo make install
	popd
	#in build dir
	cp ../tools/kvmexit.py /usr/bin/
	cd ../../
}

install_flamegraph()
{
	if [ -d "FlameGraph" ]; then
		return 1
	fi

	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git clone https://github.com/brendangregg/FlameGraph
}

install_kernel
install_qemu
install_mmtests
install_bcc
install_flamegraph
