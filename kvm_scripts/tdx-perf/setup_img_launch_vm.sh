#!/bin/bash
# Setup Ubuntu 24.04 cloud image and launch VM for TDX performance testing
# Usage:
#   ./setup_img_launch_vm.sh setup    # download and configure the image
#   ./setup_img_launch_vm.sh launch   # launch the VM
#   ./setup_img_launch_vm.sh resize   # resize disk inside guest after first boot
#   ./setup_img_launch_vm.sh all      # setup + launch

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

IMG=ubuntu-24.04-server-cloudimg-amd64.img
IMG_URL=https://cloud-images.ubuntu.com/releases/noble/release/${IMG}
BIOS_IMAGE=OVMF.fd
ROOT_PASSWORD=123456
GUEST_IP=192.168.122.100

find_bridge_helper() {
    for p in /usr/libexec/qemu-bridge-helper /usr/lib/qemu/qemu-bridge-helper; do
        if [ -f "$p" ]; then
            echo "$p"
            return
        fi
    done
    echo "ERROR: qemu-bridge-helper not found. Install qemu-system-x86." >&2
    return 1
}

setup_image() {
    echo "=== Checking dependencies ==="
    local missing=()
    for cmd in wget virt-customize qemu-img qemu-nbd; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required tools: ${missing[*]}"
        echo "Install with: sudo apt install wget libguestfs-tools qemu-utils"
        exit 1
    fi

    echo "=== Step 1: Download Ubuntu 24.04 cloud image ==="
    if [ ! -f "$IMG" ]; then
        wget "$IMG_URL"
    else
        echo "Image already exists, skipping download."
    fi

    echo "=== Step 2: Set root password ==="
    virt-customize -a "$IMG" --root-password password:${ROOT_PASSWORD}

    echo "=== Step 3: Install and configure openssh-server ==="
    virt-customize -a "$IMG" --install openssh-server \
        --run-command "systemctl enable ssh" \
        --run-command "sed -i '/PermitRootLogin/d' /etc/ssh/sshd_config" \
        --run-command "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config" \
        --run-command "sed -i '/PasswordAuthentication/d' /etc/ssh/sshd_config" \
        --run-command "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config" \
        --run-command "sed -i '/ChallengeResponseAuthentication/d' /etc/ssh/sshd_config" \
        --run-command "echo 'ChallengeResponseAuthentication yes' >> /etc/ssh/sshd_config" \
        --run-command "sed -i 's/^PasswordAuthentication/#PasswordAuthentication/' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf" \
        --run-command "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config.d/60-cloudimg-settings.conf" \
        --run-command "ssh-keygen -A"

    echo "=== Step 4: Resize disk +10G ==="
    qemu-img resize "$IMG" +10G

    echo "=== Step 5: Copy OVMF.fd ==="
    if [ ! -f "$BIOS_IMAGE" ]; then
        cp /usr/share/qemu/OVMF.fd "$BIOS_IMAGE"
    else
        echo "OVMF.fd already exists, skipping copy."
    fi

    echo "=== Step 6: Mount image via qemu-nbd for additional config ==="
    sudo modprobe nbd max_part=8
    sudo qemu-nbd --connect=/dev/nbd0 "$IMG"
    sleep 1
    sudo mount /dev/nbd0p1 /mnt

    # 6a. Disable cloud-init (prevents it from overwriting network/ssh config)
    echo "--- Disabling cloud-init ---"
    sudo touch /mnt/etc/cloud/cloud-init.disabled

    # 6b. Add UseDNS no to sshd_config (prevents SSH login delays)
    echo "--- Adding UseDNS no to sshd_config ---"
    if ! grep -q "^UseDNS no" /mnt/etc/ssh/sshd_config; then
        echo "UseDNS no" | sudo tee -a /mnt/etc/ssh/sshd_config
    fi

    # 6c. Add netplan config with static IP (required since cloud-init is disabled)
    echo "--- Adding netplan static IP config (${GUEST_IP}) ---"
    sudo tee /mnt/etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  ethernets:
    id0:
      match:
        name: "en*"
      dhcp4: no
      addresses:
        - ${GUEST_IP}/24
      routes:
        - to: default
          via: 192.168.122.1
      nameservers:
        addresses: [192.168.122.1]
EOF

    sudo umount /mnt
    sudo qemu-nbd --disconnect /dev/nbd0

    echo "=== Step 7: Fix device permissions (for non-root QEMU) ==="
    local bridge_helper
    bridge_helper=$(find_bridge_helper)
    sudo chmod 0666 /dev/kvm
    [ -e /dev/vhost-net ] && sudo chmod 0666 /dev/vhost-net
    [ -e /dev/vhost-vsock ] && sudo chmod 0666 /dev/vhost-vsock
    sudo chmod u+s "$bridge_helper"

    echo "=== Image setup complete ==="
}

launch_vm() {
    echo "=== Launching VM with bridge networking ==="
    cd "$SCRIPT_DIR"

    # Kill any existing VM with the same process name
    pkill -f "process=genvm" 2>/dev/null || true
    sleep 1

    local SERIAL_LOG="$SCRIPT_DIR/vm_serial.log"
    > "$SERIAL_LOG"

    numactl -m 0 -N 0 qemu-system-x86_64 \
        -accel kvm \
        -no-reboot \
        -name process=genvm,debug-threads=on \
        -cpu host,host-phys-bits,pmu=off \
        -smp cpus=32,sockets=4,cores=8,threads=1 \
        -m 32G \
        -object memory-backend-ram,id=mem0,size=8G \
        -object memory-backend-ram,id=mem1,size=8G \
        -object memory-backend-ram,id=mem2,size=8G \
        -object memory-backend-ram,id=mem3,size=8G \
        -numa node,cpus=0-7,nodeid=0,memdev=mem0 \
        -numa node,cpus=8-15,nodeid=1,memdev=mem1 \
        -numa node,cpus=16-23,nodeid=2,memdev=mem2 \
        -numa node,cpus=24-31,nodeid=3,memdev=mem3 \
        -machine q35,hpet=off,kernel_irqchip=split \
        -bios "$BIOS_IMAGE" \
        -display none \
        -vga none \
        -device virtio-net-pci,netdev=nic0 \
        -netdev tap,id=nic0,br=virbr0,helper=$(find_bridge_helper),vhost=on \
        -device vhost-vsock-pci,guest-cid=11 \
        -serial file:"$SERIAL_LOG" \
        -monitor none \
        -drive file="$IMG",if=virtio,format=qcow2 \
        -daemonize

    echo "VM launched in background (PID: $(pgrep -f 'process=genvm'))"
    echo "Serial log: $SERIAL_LOG"

    local SSH_CMD="sshpass -p ${ROOT_PASSWORD} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    # Wait for VM to boot and SSH to become ready
    echo "=== Waiting for SSH on ${GUEST_IP} ==="
    local max_wait=120
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if $SSH_CMD -o ConnectTimeout=3 root@"$GUEST_IP" "true" 2>/dev/null; then
            echo "SSH is ready after ${elapsed}s"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo "  waiting... (${elapsed}s / ${max_wait}s)"
    done

    if [ $elapsed -ge $max_wait ]; then
        echo "ERROR: SSH to ${GUEST_IP} not ready after ${max_wait}s"
        echo "Check serial log: tail -f $SERIAL_LOG"
        exit 1
    fi

    # Verify SSH connectivity
    echo "=== Verifying SSH connectivity ==="
    $SSH_CMD root@"$GUEST_IP" "hostname; uname -r; ip addr show | grep 'inet '"

    # Verify external network access
    echo "=== Verifying external network access ==="
    $SSH_CMD root@"$GUEST_IP" "ping -c 3 -W 5 1.1.1.1 && echo 'External network: OK' || echo 'External network: FAILED'"

    echo "=== VM is running and verified ==="
}

resize_guest_disk() {
    echo "=== Resizing guest disk (guest IP: $GUEST_IP) ==="
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@"$GUEST_IP" "growpart /dev/vda 1 && resize2fs /dev/vda1 && df -h /"
}

case "${1:-}" in
    setup)
        setup_image
        ;;
    launch)
        launch_vm
        ;;
    resize)
        resize_guest_disk
        ;;
    all)
        setup_image
        launch_vm
        ;;
    *)
        echo "Usage: $0 {setup|launch|resize|all}"
        exit 1
        ;;
esac
