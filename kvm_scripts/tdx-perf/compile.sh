#!/bin/bash
# Build kernel deb from local source tree, deploy to VM, and boot into it.
#
# Workflow:
#   1. Build kernel debs from local linux source
#   2. Upload debs to VM
#   3. Install debs on VM
#   4. Reboot VM (GRUB defaults to newest kernel)
#
# Note: If QEMU uses -no-reboot, the VM will shut down instead of
# rebooting. Relaunch it with: ./setup_img_launch_vm.sh launch

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

GUEST_IP=localhost
SSH_PORT=2222
ROOT_PASSWORD=123456
LINUX_DIR="${SCRIPT_DIR}/linux"
LOCAL_DEB_DIR="${SCRIPT_DIR}/debs"
NJOBS=$(nproc)
KERNEL_VERSION="7.1.0"
SEQ_FILE="${SCRIPT_DIR}/.compile_seq"

# Read and increment build sequence number
if [ -f "$SEQ_FILE" ]; then
    SEQ=$(cat "$SEQ_FILE")
else
    SEQ=0
fi
SEQ=$((SEQ + 1))
echo "$SEQ" > "$SEQ_FILE"
LOCAL_VERSION="-flat-v${SEQ}"
echo "=== Build sequence: ${SEQ} (CONFIG_LOCALVERSION=${LOCAL_VERSION}) ==="

SSH_OPTS="-p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh_vm() {
    sshpass -p "$ROOT_PASSWORD" ssh $SSH_OPTS root@"$GUEST_IP" "$@"
}

scp_vm() {
    sshpass -p "$ROOT_PASSWORD" scp -P ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

echo "=== Step 1: Build kernel debs from ${LINUX_DIR} ==="
cd "${LINUX_DIR}"
echo 1 > .version
# Disable debug info to reduce package size
scripts/config --disable CONFIG_DEBUG_INFO
scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
scripts/config --disable CONFIG_DEBUG_INFO_DWARF4
scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
scripts/config --enable CONFIG_DEBUG_INFO_NONE
# Set localversion to track build sequence
scripts/config --set-str CONFIG_LOCALVERSION "$LOCAL_VERSION"
make olddefconfig
make -s bindeb-pkg -j${NJOBS}

echo "=== Step 2: Collect debs (excluding libc and dbg) ==="
mkdir -p "${LOCAL_DEB_DIR}"
rm -f "${LOCAL_DEB_DIR}"/*.deb
# bindeb-pkg places debs in the parent directory; only pick up current build
DEB_LIST=$(ls "${LINUX_DIR}"/../linux-*flat-v${SEQ}*.deb 2>/dev/null | grep -v libc | grep -v dbg)
if [ -z "$DEB_LIST" ]; then
    echo "ERROR: No deb files found for flat-v${SEQ}"
    exit 1
fi
for deb in ${DEB_LIST}; do
    cp "${deb}" "${LOCAL_DEB_DIR}/"
    echo "  $(basename ${deb})"
done

echo "=== Step 3: Upload debs to VM ==="
scp_vm ${LOCAL_DEB_DIR}/*.deb root@"$GUEST_IP":~/

echo "=== Step 4: Remove old flat-v kernel packages on VM ==="
ssh_vm "dpkg -l | grep 'flat-v' | awk '{print \$2}' | xargs -r sudo dpkg -P" || true

echo "=== Step 5: Install debs on VM ==="
DEB_NAMES=$(ls "${LOCAL_DEB_DIR}"/*.deb | xargs -I{} basename {})
INSTALL_CMD=""
for deb in ${DEB_NAMES}; do
    INSTALL_CMD="${INSTALL_CMD} ~/${deb}"
done
ssh_vm "sudo dpkg -i ${INSTALL_CMD}"
ssh_vm "rm -f ${INSTALL_CMD}"

echo "=== Step 5b: Remove debs from host ==="
rm -f "${LOCAL_DEB_DIR}"/*.deb
rm -f "${LINUX_DIR}"/../linux-*flat-v${SEQ}*.deb

echo "=== Step 6: Reboot VM ==="
# GRUB defaults to the newest kernel, no grub-reboot needed.
# With QEMU -no-reboot, the VM will shut down; relaunch it manually.
ssh_vm "sudo reboot" || true

echo "=== Done ==="
echo "If QEMU uses -no-reboot, relaunch VM with: ./setup_img_launch_vm.sh launch"
echo "Then verify: ssh root@${GUEST_IP} -p ${SSH_PORT} uname -r"
