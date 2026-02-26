#!/bin/bash

# step1: first install the stress-ng package
# ./launch.sh -m -g -t

# step2: run the stress-ng
# ./launch.sh -m -g
rela_path=`dirname $0`
test_path=`cd "$rela_path" && pwd`

# initial host_ip is under virtio bridge mode, adjusted in passthrough mode later
host_ip=`ip addr show virbr0 | grep -oP 'inet \K[\d.]+'`

guest_ip=$host_ip
monitor=0
selftest=0
# need to run netperf
np=0
# need to run onednn
od=0
# need to run amx
amx=0
# need to run stress cpu
st=0
# need to run stress-ng
sg=0

# package install only
install=0
extra_cmd=""

KERNEL_IMAGE=/boot/vmlinuz-$(uname -r)
INITRD_IMAGE=/boot/initrd.img-$(uname -r)
BIOS_IMAGE=OVMF.fd
QEMU_IMAGE=qemu-system-x86_64
GUEST_IMAGE=ubuntu-2204.qcow2

# The ubuntu-24.04-server-cloudimg-amd64.img
# can be downloaded via:
# https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
# 1. use virt-customize to set the password, ubuntu 24.04 supported
#    apt install guestfs-tools
#    virt-customize -a ubuntu-24.04-server-cloudimg-amd64.img --root-password password:123456
# 2. Edit the config in VM guest(note, need to use bridge mode)
# /etc/netplan/01-netcfg.yaml
#network:
#  version: 2
#  ethernets:
#    enp0s1:
#      dhcp4: true
#      optional: true
# or:
#network:
#  version: 2
#  ethernets:
#    enp0s1:
#      dhcp4: no
#      addresses:
#        - 10.0.2.15/24
#      routes:
#        - to: default
#          via: 10.0.2.2
#      nameservers:
#        addresses:
#          - 8.8.8.8
#          - 8.8.4.4
#
# 3. netplan apply
# 4. sudo ssh-keygen -A
#    ssh-keygen: generating new host keys: RSA ECDSA ED25519
# 5. paste the public key of the host to the guest's ~/.ssh/authorized_keys
# 6. enable authorized key/password login:
#    /etc/ssh/sshd_config
#    PubkeyAuthentication yes
#    AuthorizedKeysFile      .ssh/authorized_keys
#    PasswordAuthentication yes
# 7. sudo systemctl restart ssh
# 8. need to extend the disk size by:
#    qemu-img resize ubuntu-24.04-server-cloudimg-amd64.img +10G
#    sudo growpart /dev/vda 1
#    sudo resize2fs /dev/vda1
#    df -h
GUEST_IMAGE=ubuntu-24.04-server-cloudimg-amd64.img
KERNEL_SRC=linux-tdx-src
QEMU_SRC=qemu-tdx-src
MMTESTS_SRC=mmtests

#user nic
netstr="-device virtio-net-pci,netdev=nic0 
	-netdev user,id=nic0,hostfwd=tcp::10022-:22  "

#virtio nic - > could be replaced by passthrough nic at runtime
netstr="-device virtio-net-pci,netdev=nic0 \
        -netdev tap,id=nic0,br=virbr0,helper=/usr/libexec/qemu-bridge-helper,vhost=on \
        -device vhost-vsock-pci,guest-cid=11 "

#gpu passthrough
#-object iommufd,id=iommufd0 \
#-device pcie-root-port,id=pci.1,bus=pcie.0 \
#-device vfio-pci,host=97:00.0,id=nv_gpu,bus=pci.1,iommufd=iommufd0 \


#number of vcpus, bind to physical cpus starts from 1 to NR_VCPUS-1
NR_VCPUS=16
# something like 0000:16:00.0
HOST_NIC_BFD=""
GUEST_NIC_BFD=""
#test duration in seconds
DURATION=30

#   -smp cpus=${NR_VCPUS},sockets=4,cores=$((NR_VCPUS/4)),threads=1 \
#        -object memory-backend-ram,id=mem0,size=8G \
#        -object memory-backend-ram,id=mem1,size=8G \
#        -object memory-backend-ram,id=mem2,size=8G \
#        -object memory-backend-ram,id=mem3,size=8G \
#        -numa node,cpus=0-3,nodeid=0,memdev=mem0 \
#        -numa node,cpus=4-7,nodeid=1,memdev=mem1 \
#        -numa node,cpus=8-11,nodeid=2,memdev=mem2 \
#        -numa node,cpus=12-15,nodeid=3,memdev=mem3 \
#        -m 32G \
#

function pre_install() {
	. $test_path/preinstall.sh $KERNEL_SRC $QEMU_SRC $QEMU_IMAGE $MMTESTS_SRC $NR_VCPUS $DURATION
}

function run_kselftest() {
	if [ "$selftest" = "1" ]; then
		source $test_path/kselftest.sh
		# 3 loops, 10G, 20G, 30G
		run_kselftest 3
	fi
}

function launch_tdx_vm() {

	TDX_SYSFS_FILE="/sys/module/kvm_intel/parameters/tdx"
	if [[ -f $TDX_SYSFS_FILE ]]; then
		if [ "Y" != "$(cat $TDX_SYSFS_FILE)" ] ;then
			echo "Please set tdx kvm_intel params to Y"
			exit 1
		fi
	else
		echo "tdx modules params does not exist, reload correct kvm"
		exit 1
	fi

  numactl -m 0 -N 0 $QEMU_IMAGE \
        -accel kvm \
        -no-reboot \
        -name process=tdxvm,debug-threads=on \
        -cpu host,host-phys-bits,pmu=off \
        -smp cpus=${NR_VCPUS},sockets=1 \
        -m 16G \
        -object '{"qom-type":"tdx-guest","id":"tdx","quote-generation-socket":{"type": "vsock", "cid":"2","port":"1234"}}' \
        -object memory-backend-ram,id=ram1,size=16G \
        -machine q35,hpet=off,kernel_irqchip=split,confidential-guest-support=tdx,memory-backend=ram1 \
        -bios $BIOS_IMAGE \
        -nographic \
        -vga none \
        ${netstr}-chardev stdio,id=mux,mux=on,signal=off \
        -device virtio-serial,romfile= \
        -device virtconsole,chardev=mux \
        -serial chardev:mux \
        -monitor chardev:mux \
        -drive file=${GUEST_IMAGE},if=virtio,format=qcow2 \
        -kernel ${KERNEL_IMAGE} \
	-initrd ${INITRD_IMAGE} \
	-append "root=/dev/vda1 rw console=hvc0 earlyprintk=ttyS0 ignore_loglevel earlyprintk l1tf=off log_buf_len=200M nokaslr tsc=reliable apparmor=0 ${extra_cmd}" \
        -monitor pty &

	sleep 45
}

function launch_gen_vm_numa() {

  numactl -m 0 -N 0 $QEMU_IMAGE \
        -accel kvm \
        -no-reboot \
        -name process=genvm,debug-threads=on \
        -cpu host,host-phys-bits,pmu=off \
        -smp cpus=${NR_VCPUS},sockets=4,cores=$((NR_VCPUS/4)),threads=1 \
        -object memory-backend-ram,id=mem0,size=8G \
        -object memory-backend-ram,id=mem1,size=8G \
        -object memory-backend-ram,id=mem2,size=8G \
        -object memory-backend-ram,id=mem3,size=8G \
        -numa node,cpus=0-7,nodeid=0,memdev=mem0 \
        -numa node,cpus=8-15,nodeid=1,memdev=mem1 \
        -numa node,cpus=16-23,nodeid=2,memdev=mem2 \
        -numa node,cpus=24-31,nodeid=3,memdev=mem3 \
        -m 32G \
        -machine q35,kernel_irqchip=split \
        -nographic \
        -vga none \
        ${netstr}-chardev stdio,id=mux,mux=on,signal=off \
        -device virtio-serial,romfile= \
        -device virtconsole,chardev=mux \
        -serial chardev:mux \
        -monitor chardev:mux \
	-device virtio-blk-pci,drive=virtio-disk0 \
	-drive file=${GUEST_IMAGE},if=none,id=virtio-disk0 \
        -monitor pty

        #sleep 45
}

function launch_gen_vm_simple() {

  numactl -m 0 -N 0 $QEMU_IMAGE \
        -accel kvm \
        -no-reboot \
        -name process=genvm,debug-threads=on \
        -cpu host,host-phys-bits,pmu=off \
        -smp cpus=${NR_VCPUS},sockets=1 \
        -m 4G \
        -machine q35,kernel_irqchip=split \
        -nographic \
        -vga none \
        ${netstr}-chardev stdio,id=mux,mux=on,signal=off \
        -device virtio-serial,romfile= \
        -device virtconsole,chardev=mux \
        -serial chardev:mux \
        -monitor chardev:mux \
        -drive file=${GUEST_IMAGE},if=virtio,format=qcow2 \
        -monitor pty &

	sleep 45
}

function launch_gen_vm() {

  numactl -m 0 -N 0 $QEMU_IMAGE \
        -accel kvm \
        -no-reboot \
        -name process=genvm,debug-threads=on \
        -cpu host,host-phys-bits,pmu=off \
        -smp cpus=${NR_VCPUS},sockets=1 \
        -m 16G \
        -object memory-backend-ram,id=ram1,size=16G \
        -machine q35,hpet=off,kernel_irqchip=split,memory-backend=ram1 \
        -bios $BIOS_IMAGE \
        -nographic \
        -vga none \
        ${netstr}-chardev stdio,id=mux,mux=on,signal=off \
        -device virtio-serial,romfile= \
        -device virtconsole,chardev=mux \
        -serial chardev:mux \
        -monitor chardev:mux \
        -drive file=${GUEST_IMAGE},if=virtio,format=qcow2 \
        -monitor pty

	#sleep 45
}

function bind_vcpu() {
	pcpu=1
	end_pcpu=$((${NR_VCPUS}-1))
	for i in $(seq 0 1 ${end_pcpu}); do
	### vCPUi pin to pCPU(i+1) #############
		pid=`ps -eT -o tid,comm | grep "CPU $i/KVM" | awk '{print $1}'`
		if [[ -n $pid ]]; then
			echo thread id $pid vcpu$i : on cpu $pcpu
			taskset -pc $pcpu $pid
		fi
		pcpu=$((pcpu+1))
	done
}

function stabilize_host() {

	pkill -9 tuned
	pepc.standalone pstates config --governor performance
	pepc.standalone pstates config --turbo off
	pepc.standalone cstates config --disable C6
	echo 3 > /proc/sys/vm/drop_caches
}

function launch_vm() {
	tdx=$1
	pt=$2

	# kill existing vm
	pid=$(pgrep -f ${QEMU_IMAGE})
	if [[ -n $pid ]]; then
		echo "kill vm guest $pid"
		kill $pid
		sleep 5
	fi

	if [[ ! -f $BIOS_IMAGE ]]; then
		echo "Please provide OVMF.fd"
		exit 1
	fi

	if [[ ! -f $GUEST_IMAGE ]]; then
		echo "Please provide the OS disk image"
		exit 1
	fi

	if [ "$pt" = "1" ]; then
		if [ -z $GUEST_NIC_BFD ] || [ -z $HOST_NIC_BFD ]; then
			echo "Please provide the GUEST_NIC_BFD and HOST_NIC_BFD for passthrough mode:"
			prompt=$(lspci -D | grep Ethernet)
			echo "$prompt"
			exit 1
		fi

		modprobe vfio-pci

		# attach to the vfio-pci driver
		if [ ! -e "/sys/bus/pci/drivers/vfio-pci/${GUEST_NIC_BFD}" ]; then
			# unattach the original driver
			pt_path="/sys/bus/pci/devices/${GUEST_NIC_BFD}/driver"
			if [ -e "${pt_path}" ]; then
				echo ${GUEST_NIC_BFD} > ${pt_path}/unbind
			fi

			bind=$(lspci -s ${GUEST_NIC_BFD} -n | awk '{gsub(":", " "); print $4, $5}')
			echo $bind > /sys/bus/pci/drivers/vfio-pci/new_id
		fi

		# passthrough the guest nic
		netstr="-device vfio-pci,host=${GUEST_NIC_BFD} "
		# let guest be aware of the host's ip
		host_nic_name=$(ls /sys/bus/pci/devices/$HOST_NIC_BFD/net/)
		host_ip=$(ip addr show $host_nic_name | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
		extra_cmd=" host_ip=$host_ip host_path=$test_path"
	fi

	if [ "$tdx" = "0" ]; then
		launch_gen_vm
	fi
	if [ "$tdx" = "1" ]; then
		launch_tdx_vm
	fi
	if [ "$tdx" = "2" ]; then
		launch_gen_vm_simple
	fi
	if [ "$tdx" = "3" ]; then
		launch_gen_vm_numa
	fi
	bind_vcpu
}

function run_monitor() {

	benchmark=$1
	prestr=$2
	test_path=$3
	delay=$4
	sample=$5

	if [ "$monitor" = "1" ]; then
		# start delay seconds, sample seconds
		#. $test_path/kvmstat.sh $delay $sample ${test_path} $test_path/kvmexit_${benchmark}_${prestr}.log &
		#. $test_path/interrupt_delta.sh $delay $sample  > $test_path/irqs_${benchmark}_${prestr}.log &
		. $test_path/flamegraph.sh $delay $sample ${test_path} ${test_path}/flamegraph_${benchmark}_${prestr}.svg &
	fi
}

function setup_proxy() {
	export http_proxy='http://child-prc.intel.com:913';
	export https_proxy='http://child-prc.intel.com:913';
	git config --global http.postBuffer 524288000;
	git config --global http.proxy 'http://child-prc.intel.com:913'
	git config --global https.proxy 'http://child-prc.intel.com:913'
}

function run_benchmarks() {

	tdx=$1
	str="gen"
	if [ "$tdx" = "1" ]; then
		str="tdx"
	fi

	pt=$2
	if [ "$pt" = "1" ]; then
		# passthrough mode
		str=$str"-pt"
		guest_ip=$(cat guest_ip.log)
	else
		# virtio bridge mode
		str=$str"-nopt"
		file="/var/lib/libvirt/dnsmasq/virbr0.status"
		guest_ip=$(jq -r '.[]["ip-address"]' $file)
	fi

	if [ "$install" = "1" ]; then
		monitor="0"
	fi

	# netperf
	if [ "$np" = "1" ]; then
		cd $test_path/$MMTESTS_SRC
		cp ../config-netperf ./
		sed -i "s/export MMTESTS_VMS_IP=\"\"/export MMTESTS_VMS_IP=\"$guest_ip\"/g" config-netperf
		sed -i "s/export REMOTE_SERVER_HOST=\"\"/export REMOTE_SERVER_HOST=\"$host_ip\"/g" config-netperf
		setup_proxy
		run_monitor netperf $str ${test_path} 45 3
		./run-kvm.sh -k -L -n --vm vm1 --config config-netperf $str ${NR_VCPUS}
		cd ..
	fi

	# stress-ng memory
	if [ "$sg" = "1" ]; then
		cd $test_path/$MMTESTS_SRC
		cp ../config-stressng ./
		sed -i "s/export MMTESTS_VMS_IP=\"\"/export MMTESTS_VMS_IP=\"$guest_ip\"/g" config-stressng
		setup_proxy
		run_monitor stressng $str ${test_path} 70 3
		./run-kvm.sh -k -L -n --vm vm1 --config config-stressng $str ${NR_VCPUS}
		cd ..
	fi

	# stream
	if [ "$sm" = "1" ]; then
		cd $test_path/$MMTESTS_SRC
		cp ../config-stream ./
		# 1.5 GB
		sed -i "s/STREAM_SIZE=/STREAM_SIZE=1610612736/g" config-stream
		sed -i "s/export MMTESTS_VMS_IP=\"\"/export MMTESTS_VMS_IP=\"$guest_ip\"/g" config-stream
		run_monitor stream $str ${test_path} 25 3
		./run-kvm.sh -k -L -n --vm vm1 --config config-stream $str ${NR_VCPUS}
		cd ..
	fi

	# oneDNN
	if [ "$od" = "1" ]; then
		cp $test_path/onednn.sh $test_path/onednn_guest.sh
		sed -i "s/PREFIX/${str}/g" $test_path/onednn_guest.sh
		if [ "$install" = "1" ]; then
			sed -i "s/install=0/install=1/g" $test_path/onednn_guest.sh
		fi
		scp $test_path/onednn_guest.sh $guest_ip:~/
		# FIXME: start monitor 3 seconds later, lasts for 3 seconds
		run_monitor onednn $str ${test_path} 3 3
		ssh $guest_ip ./onednn_guest.sh
	fi

	# run amx
	if [ "$amx" = "1" ]; then
		cp $test_path/amx.sh $test_path/amx_guest.sh
		sed -i "s/PREFIX/${str}/g" $test_path/amx_guest.sh
		sed -i "s/\$duration/60/g" $test_path/amx_guest.sh
		sed -i "s/\$nr_thread/${NR_VCPUS}/g" $test_path/amx_guest.sh
		sed -i "s/\$bufsize/8192/g" $test_path/amx_guest.sh
		if [ "$install" = "1" ]; then
			sed -i "s/install=0/install=1/g" $test_path/amx_guest.sh
		fi
		scp $test_path/amx_guest.sh $guest_ip:~/
		# FIXME: start monitor 15 seconds later, lasts for 3 seconds
		run_monitor amx $str ${test_path} 10 3
		ssh $guest_ip ./amx_guest.sh
	fi

	# run pure cpu intensive workload
	if [ "$st" = "1" ]; then
		cp $test_path/stress-ng.sh $test_path/stress-ng_guest.sh
		sed -i "s/PREFIX/${str}/g" $test_path/stress-ng_guest.sh
		sed -i "s/\$nr_instance/${NR_VCPUS}/g" $test_path/stress-ng_guest.sh
		sed -i "s/\$duration/100/g" $test_path/stress-ng_guest.sh
		if [ "$install" = "1" ]; then
			sed -i "s/install=0/install=1/g" $test_path/stress-ng_guest.sh
		fi
		scp $test_path/stress-ng_guest.sh $guest_ip:~/
		# FIXME: start monitor 30 seconds later, lasts for 3 seconds
		run_monitor stress-ng $str ${test_path} 10 3
		ssh $guest_ip ./stress-ng_guest.sh
	fi
}

function get_benchmarks_result() {
	if [ "$np" = "1" ]; then
		cd $test_path/$MMTESTS_SRC
		#./bin/compare-mmtests.pl --directory work/log --benchmark netperf-ipv4-udp-rr --names gen-vm1,tdx-vm1 &> $test_path/compare_netperf_ipv4_udp_rr.log
		# compare the passthrough result
		./bin/compare-mmtests.pl --directory work/log --benchmark netperf-ipv4-udp-rr --names gen-pt-vm1,tdx-pt-vm1 &> $test_path/compare_netperf_ipv4_udp_rr.log
		cd ..
	fi

	if [ "$sg" = "1" ]; then
		cd $test_path/$MMTESTS_SRC
		./bin/compare-mmtests.pl --directory work/log --benchmark stressng --names gen-pt-vm1,tdx-pt-vm1 &> $test_path/compare_stressng.log
		cd ..
	fi

	if [ "$sm" = "1" ]; then
		cd $test_path/$MMTESTS_SRC
		./bin/compare-mmtests.pl --directory work/log --benchmark stream --names gen-pt-vm1,tdx-pt-vm1 &> $test_path/compare_stream.log
		cd ..
	fi

	if [ "$od" = "1" ]; then
		scp $guest_ip:~/*.log $test_path/
		source $test_path/onednn_guest.sh
		#compare_dnn $test_path/gen-pt-training.log $test_path/tdx-pt-training.log > $test_path/compare_onednn_training_pt.log
		#compare_dnn $test_path/gen-pt-inference-lb.log $test_path/tdx-pt-inference-lb.log > $test_path/compare_onednn_inference_lb_pt.log
		#compare_dnn $test_path/gen-pt-inference-batched.log $test_path/tdx-pt-inference-batched.log > $test_path/compare_onednn_inference_batched_pt.log
		compare_dnn $test_path/gen-pt-matmul.log $test_path/tdx-pt-matmul.log > $test_path/compare_onednn_matmul_pt.log
	fi

	if [ "$amx" = "1" ]; then
		scp $guest_ip:~/*.log $test_path/
		source $test_path/amx_guest.sh
		compare_amx $test_path/gen-pt-amx.log $test_path/tdx-pt-amx.log > $test_path/compare_amx_pt.log
	fi
}

while getopts ":hmsnoacgtr" opt; do
  case ${opt} in
    m)
      monitor=1
      ;;
    s)
      selftest=1
      ;;
    n)
      np=1 #netperf
      ;;
    g)
      sg=1 #stress-ng memory
      ;;
    o)
      od=1 #onednn
      ;;
    a)
      amx=1 #simple amx test
      ;;
    c)
      st=1 #stress cpu
      ;;
    t)
      install=1
      ;;
    r)
      sm=1 # stream
      ;;
    h)
      echo "Usage: -m [monitor] -s [kselftest] -n [netperf] -o [onednn] -a [amx] -c [stress-cpu]"\
	   "-t [install only] -r [stream] -g [stress-ng memory]"
      exit 1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" 1>&2
      ;;
  esac
done

rm -rf *.log
rm -rf *.svg

#pre_install
#stabilize_host
#run_kselftest

# run non-tdx benchmarks
launch_vm 0 0
#run_benchmarks 0 1

# run tdx benchmarks
#launch_vm 1 1
#run_benchmarks 1 1

#get_benchmarks_result
