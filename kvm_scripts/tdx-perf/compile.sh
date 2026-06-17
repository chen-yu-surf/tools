#!/bin/bash
# Build kernel on gnr, deploy to VM, and boot into it.
#
# Workflow:
#   1. Copy VM's current kernel config to host
#   2. SCP config to gnr:/home/chenyu/linux/.config
#   3. Clean old debs on gnr, fix config, build kernel debs
#   4. SCP debs (excluding libc and dbg) back to host
#   5. Upload debs to VM
#   6. Install debs on VM (sudo)
#   7. Reboot VM (GRUB defaults to newest kernel)
#
# Note: If QEMU uses -no-reboot, the VM will shut down instead of
# rebooting. Relaunch it with: ./setup_img_launch_vm.sh launch

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

GUEST_HOST=vm
GNR_HOST=gnr
GNR_LINUX_DIR=/home/chenyu/linux
GNR_DEB_DIR=/home/chenyu
LOCAL_DEB_DIR="${SCRIPT_DIR}/debs"

ssh_vm() {
    ssh ${GUEST_HOST} "$@"
}

scp_vm() {
    scp "$@"
}

echo "=== Step 1: Copy VM kernel config to host ==="
ssh_vm "cat /boot/config-\$(uname -r)" > "${SCRIPT_DIR}/vm_kernel_config"
echo "Saved VM kernel config to ${SCRIPT_DIR}/vm_kernel_config"

echo "=== Step 2: Upload config to gnr ==="
scp "${SCRIPT_DIR}/vm_kernel_config" ${GNR_HOST}:${GNR_LINUX_DIR}/.config
echo "Config uploaded to ${GNR_HOST}:${GNR_LINUX_DIR}/.config"

echo "=== Step 3: Clean old debs and build kernel on gnr ==="
ssh ${GNR_HOST} "rm -f ${GNR_DEB_DIR}/linux-*.deb"
# Fix Ubuntu-specific config values incompatible with the gnr kernel tree
# env -i prevents forwarding zh_CN locale vars that cause perl warnings on gnr
env -i HOME="$HOME" PATH="$PATH" SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" \
ssh ${GNR_HOST} "cd ${GNR_LINUX_DIR} && \
    sed -i 's|CONFIG_SYSTEM_TRUSTED_KEYS=.*|CONFIG_SYSTEM_TRUSTED_KEYS=\"\"|' .config && \
    sed -i 's|CONFIG_SYSTEM_REVOCATION_KEYS=.*|CONFIG_SYSTEM_REVOCATION_KEYS=\"\"|' .config && \
    sed -i '/CONFIG_CRYPTO_LIB_POLY1305_GENERIC/d' .config && \
    sed -i '/CONFIG_CRYPTO_LIB_POLY1305=m/s/=m/=y/' .config && \
    sed -i '/CONFIG_CRYPTO_LIB_CURVE25519_GENERIC/d' .config && \
    sed -i '/CONFIG_FB_BACKLIGHT/d' .config && \
    sed -i '/CONFIG_HYPERV=m/d' .config && \
    sed -i '/CONFIG_ANDROID_BINDER_IPC=m/d' .config && \
    sed -i '/CONFIG_ANDROID_BINDERFS=m/d' .config && \
    sed -i '/CONFIG_MULTIPLEXER=m/d' .config && \
    echo 1 > .version && \
    make olddefconfig && make clean && make bindeb-pkg -j256"

echo "=== Step 4: Download debs from gnr (excluding libc and dbg) ==="
mkdir -p "${LOCAL_DEB_DIR}"
rm -f "${LOCAL_DEB_DIR}"/*.deb
DEB_LIST=$(ssh ${GNR_HOST} "ls ${GNR_DEB_DIR}/linux-*.deb 2>/dev/null | grep -v libc | grep -v dbg")
if [ -z "$DEB_LIST" ]; then
    echo "ERROR: No deb files found on gnr"
    exit 1
fi
for deb in ${DEB_LIST}; do
    echo "Downloading $(basename ${deb})..."
    scp ${GNR_HOST}:"${deb}" "${LOCAL_DEB_DIR}/"
done

echo "=== Step 5: Upload debs to VM ==="
scp_vm "${LOCAL_DEB_DIR}"/*.deb ${GUEST_HOST}:~/

echo "=== Step 6: Install debs on VM ==="
DEB_NAMES=$(ls "${LOCAL_DEB_DIR}"/*.deb | xargs -I{} basename {})
INSTALL_CMD=""
for deb in ${DEB_NAMES}; do
    INSTALL_CMD="${INSTALL_CMD} ~/${deb}"
done
ssh_vm "sudo dpkg -i ${INSTALL_CMD}"
ssh_vm "rm -f ${INSTALL_CMD}"

echo "=== Step 7: Reboot VM ==="
# GRUB defaults to the newest kernel, no grub-reboot needed.
# With QEMU -no-reboot, the VM will shut down; relaunch it manually.
ssh_vm "sudo reboot" || true

echo "=== Done ==="
echo "If QEMU uses -no-reboot, relaunch VM with: ./setup_img_launch_vm.sh launch"
echo "Then verify: ssh ${GUEST_HOST} uname -r"
