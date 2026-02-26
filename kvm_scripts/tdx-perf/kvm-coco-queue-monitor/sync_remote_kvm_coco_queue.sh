#!/usr/bin/bash

set -x

GIT=/usr/bin/git
#project_dir=/home/sdp/fyin/kvm_coco_snapshot
project_dir=/data/nvme/src/fengwei/kvm_coco_snapshot
logfile=$project_dir/sync.log

log_dir=/data/nvme/src/fengwei
logfile=$log_dir/test.log

upstream_kvm_url=https://git.kernel.org/pub/scm/virt/kvm/kvm.git
upstream_kvm_dir=$project_dir/kvm_upstream

#kvm_coco_queue_snap_url=git@github.com:intel/tdx.git
kvm_coco_queue_snap_url=https://github.com/intel/tdx.git
kvm_coco_queue_snap_dir=$project_dir/kvm_coco_queue

export http_proxy='http://child-prc.intel.com:913'
export https_proxy='http://child-prc.intel.com:913'

# first update the upstream kvm local repo
echo `date +%Y%m%d` >> $logfile
if [ ! -d $upstream_kvm_dir ]; then
	$GIT clone $upstream_kvm_url $upstream_kvm_dir
else
	cd $upstream_kvm_dir
	$GIT fetch --all -t
	echo "git fetch $upstream_kvm_url successfully" >> $logfile
fi

if [ ! -d $upstream_kvm_dir ]; then
	echo "git clone $upstream_kvm_url failed" >> $logfile
	exit
else
	echo "git clone $upstream_kvm_url successfully" >> $logfile
fi

# second update the intel tdx snapshot local repo
if [ ! -d $kvm_coco_queue_snap_dir ]; then
	$GIT clone $kvm_coco_queue_snap_url $kvm_coco_queue_snap_dir
else
	cd $kvm_coco_queue_snap_dir
	$GIT fetch --all -t
	echo "git fetch $kvm_coco_queue_snap_url successfully" >> $logfile
fi

if [ ! -d $kvm_coco_queue_snap_dir ]; then
	echo "git clone $kvm_coco_queue_snap_url failed" >> $logfile
	exit
else
	echo "git clone $kvm_coco_queue_snap_url successfully" >> $logfile
fi

# check the head commit of kvm upstream repo
cd $upstream_kvm_dir
kvm_coco_queue_hash=`$GIT show --pretty=%h remotes/origin/kvm-coco-queue | head -n 1`
echo "coco queue hash:"$kvm_coco_queue_hash

tag_date=`date +%Y%m%d`
tag_name=kvm-coco-queue-snapshot/kvm-coco-queue-snapshot-$tag_date

cd $kvm_coco_queue_snap_dir

# check if the local intel tdx snapshot has the latest repo
if [ `$GIT tag --contain $kvm_coco_queue_hash` ]; then
	echo "tag $kvm_coco_queue_hash has already been created, quit..."
	exit
else
	echo "tag $kvm_coco_queue_hash was not found"
fi

# if upstream kvm has newer commit, prepare to create 1 new snapshot
# locally on intel tdx repo, and push it to remote intel tdx repo,
# using a new tag
cd $upstream_kvm_dir

#echo "git tag -m snapshot of kvm-coco-queue branch in the KVM repo on $tag_date $tag_name $kvm_coco_queue_hash"

# In case we pushed an incorrect tag to kvm-coco-queue-snapshot:
# Optional: Delete the tag locally
# git tag -d kvm-coco-queue-snapshot/kvm-coco-queue-snapshot-20241104
# Delete the tag from the remote repository
# git push origin --delete refs/tags/kvm-coco-queue-snapshot/kvm-coco-queue-snapshot-20241104

# create the tag on local intel tdx snapshot repo
if [ `$GIT tag -m "snapshot of kvm-coco-queue branch in the KVM repo on $tag_date" $tag_name $kvm_coco_queue_hash` ]; then
	echo "local tag $tag_name for hash $kvm_coco_queu_hash failed" >> $logfile
else
	echo "local tag $tag_name for hash $kvm_coco_queu_hash created" >> $logfile
fi

# try to push to remote intel tdx snapshot repo
if [ `$GIT push $kvm_coco_queue_snap_url $tag_name:refs/tags/$tag_name` ]; then
	echo "remote tag $tag_name not created" >> $logfile
else
	echo "remote tag $tag_name created" >> $logfile
fi

cd ${project_dir}
sed -i "s/DATE/${tag_date}/g" email_body.patch
git send-email --to=yu.c.chen@intel.com --to=julie.du@intel.com --confirm=never email_body.patch
sed -i "s/${tag_date}/DATE/g" email_body.patch
