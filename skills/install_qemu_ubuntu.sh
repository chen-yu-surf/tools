#!/usr/bin/env bash
#
# install_qemu_ubuntu.sh - from scratch: install QEMU, download the Ubuntu 24.04
# cloud image, prepare it (user "chenyu" / password "intel@123", sshd with
# password auth, network, bigger disk) and launch it with a host->guest SSH
# port forward so that the host can do:
#
#     ssh -p 2222 chenyu@127.0.0.1        (password: intel@123)
#
# Tested on an Ubuntu 24.04 host with /dev/kvm available.
#
# Usage:
#   ./install_qemu_ubuntu.sh              # do everything (steps 1..7) and boot
#   ./install_qemu_ubuntu.sh prepare      # steps 1..5 only (no boot)
#   ./install_qemu_ubuntu.sh run          # just boot the VM (headless, daemonized)
#   ./install_qemu_ubuntu.sh run-fg       # boot in the foreground, serial on this tty
#   ./install_qemu_ubuntu.sh ssh          # ssh into the guest as chenyu
#   ./install_qemu_ubuntu.sh stop         # shut the VM down
#   ./install_qemu_ubuntu.sh clean        # remove the working qcow2 (keeps the download)
#
set -euo pipefail

########################################  configuration  ######################
WORKDIR="${WORKDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

BASE_URL="https://cloud-images.ubuntu.com/releases/noble/release"
BASE_IMG_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
BASE_IMG="$WORKDIR/$BASE_IMG_NAME"          # pristine download, never booted
DISK="$WORKDIR/ubuntu-24.04.qcow2"          # the disk the VM actually runs on

VM_USER="chenyu"
VM_PASS="intel@123"
ROOT_PASS="123456"                          # as in reference_qemu.txt

SSH_PORT="${SSH_PORT:-2222}"                # host port forwarded to guest :22
VM_MEM="${VM_MEM:-4G}"
VM_CPUS="${VM_CPUS:-32}"
DISK_GROW="${DISK_GROW:-+10G}"              # extra space added to the cloud image

PIDFILE="$WORKDIR/qemu.pid"
MONITOR="$WORKDIR/qemu-monitor.sock"
SERIAL_LOG="$WORKDIR/serial.log"

# libguestfs on Ubuntu cannot read /boot/vmlinuz-* as a normal user (mode 0600),
# so virt-customize is run under sudo. "direct" backend = no libvirt needed.
export LIBGUESTFS_BACKEND=direct

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

###############################################################################
# Step 1 - install QEMU + the tools used to customize the cloud image
###############################################################################
step1_install_packages() {
    say "Step 1/7: installing QEMU and helper packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        qemu-system-x86 \
        qemu-utils \
        libguestfs-tools \
        guestfs-tools \
        cloud-image-utils \
        genisoimage \
        bridge-utils \
        openssh-client \
        sshpass \
        curl

    qemu-system-x86_64 --version | head -1
    # KVM is optional (QEMU falls back to TCG emulation) but ~10x faster.
    if [[ -w /dev/kvm ]]; then
        echo "KVM: available ($(ls -l /dev/kvm))"
    else
        echo "KVM: NOT writable by $(id -un); add yourself to the kvm group:"
        echo "     sudo usermod -aG kvm $(id -un)   # then log out/in"
    fi
}

###############################################################################
# Step 2 - download the Ubuntu 24.04 server cloud image
###############################################################################
step2_download_image() {
    say "Step 2/7: downloading $BASE_IMG_NAME"
    if [[ -f "$BASE_IMG" ]]; then
        echo "already present: $BASE_IMG ($(du -h "$BASE_IMG" | cut -f1))"
    else
        curl -fL --retry 3 -C - -o "$BASE_IMG.part" "$BASE_URL/$BASE_IMG_NAME"
        mv "$BASE_IMG.part" "$BASE_IMG"
    fi
    qemu-img info "$BASE_IMG"
}

###############################################################################
# Step 3 - make a working copy and grow it (reference_qemu.txt item 6)
#          The cloud image is only 3.5G; +10G gives room for packages.
#          growpart/resize2fs are run inside the guest on first boot (step 4).
###############################################################################
step3_prepare_disk() {
    say "Step 3/7: creating working disk $DISK and growing it by $DISK_GROW"
    [[ -f "$DISK" ]] && { echo "removing previous $DISK"; rm -f "$DISK"; }
    cp --sparse=always "$BASE_IMG" "$DISK"
    qemu-img resize "$DISK" "$DISK_GROW"
    qemu-img info "$DISK" | head -4
}

###############################################################################
# Step 4 - customize the image offline with virt-customize:
#            * root password                       (reference item 1)
#            * user "chenyu" / "intel@123" + sudo
#            * openssh-server, password login       (reference items 2 and 3)
#            * static netplan config                (reference item 4)
#            * grow the root filesystem on first boot (reference item 6)
###############################################################################
step4_customize_image() {
    say "Step 4/7: customizing the image (user $VM_USER, sshd, network, growfs)"

    # netplan: match every "en*" NIC so it works whatever QEMU names it
    # (enp0s2 / ens3 / ...). dhcp4 -> the user-mode net gives 10.0.2.15.
    local netplan_yaml="$WORKDIR/.01-netcfg.yaml"
    cat > "$netplan_yaml" <<'EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: en*
      dhcp4: true
      optional: true
EOF

    # sshd drop-in: the cloud image ships 60-cloudimg-settings.conf with
    # "PasswordAuthentication no"; a later-sorting file wins.
    local sshd_dropin="$WORKDIR/.99-qemu-lab.conf"
    cat > "$sshd_dropin" <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
UsePAM yes
EOF

    sudo -E virt-customize -a "$DISK" \
        --root-password "password:$ROOT_PASS" \
        --run-command "useradd -m -s /bin/bash -c 'chenyu' $VM_USER || true" \
        --password "$VM_USER:password:$VM_PASS" \
        --run-command "usermod -aG sudo,adm $VM_USER" \
        --run-command "passwd -u $VM_USER || true" \
        --run-command "chage -M -1 -E -1 $VM_USER || true" \
        --run-command "echo '$VM_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-$VM_USER" \
        --run-command "chmod 440 /etc/sudoers.d/90-$VM_USER" \
        --install openssh-server,sudo,cloud-guest-utils \
        --run-command "systemctl enable ssh" \
        --run-command "sed -i '/^PermitRootLogin/d;/^#PermitRootLogin/d' /etc/ssh/sshd_config" \
        --run-command "sed -i '/^PasswordAuthentication/d;/^#PasswordAuthentication/d' /etc/ssh/sshd_config" \
        --run-command "printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' >> /etc/ssh/sshd_config" \
        --run-command "sed -i 's/^PasswordAuthentication/#PasswordAuthentication/' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf || true" \
        --upload "$sshd_dropin:/etc/ssh/sshd_config.d/99-qemu-lab.conf" \
        --run-command "chmod 644 /etc/ssh/sshd_config.d/99-qemu-lab.conf" \
        --run-command "ssh-keygen -A" \
        --upload "$netplan_yaml:/etc/netplan/01-netcfg.yaml" \
        --run-command "chmod 600 /etc/netplan/01-netcfg.yaml" \
        --run-command "rm -f /etc/netplan/50-cloud-init.yaml" \
        --run-command "touch /etc/cloud/cloud-init.disabled" \
        --run-command "systemctl mask cloud-init cloud-init-local cloud-config cloud-final || true" \
        --hostname "ubuntu-qemu" \
        --firstboot-command "growpart /dev/vda 1 || true; resize2fs /dev/vda1 || true; netplan apply || true; systemctl restart ssh || true"

    rm -f "$netplan_yaml" "$sshd_dropin"

    # cloud-init is disabled (no datasource is attached), so the netplan file
    # above provides networking and the firstboot command does the resize that
    # cloud-init would normally have performed.
    say "Step 4 done: image customized"
}

###############################################################################
# Step 5 - sanity check the customization from the host, without booting
###############################################################################
step5_verify_image() {
    say "Step 5/7: verifying the image offline"
    sudo -E virt-cat -a "$DISK" /etc/passwd | grep "^$VM_USER:" \
        || die "user $VM_USER missing from the image"
    sudo -E virt-cat -a "$DISK" /etc/shadow | grep "^$VM_USER:" | cut -d: -f1,2 \
        | sed 's/:\(.\{12\}\).*/:\1... (hash present)/'
    sudo -E virt-cat -a "$DISK" /etc/ssh/sshd_config.d/99-qemu-lab.conf
    sudo -E virt-ls -a "$DISK" /etc/netplan
}

###############################################################################
# Step 6 - launch the VM
#          -nic user,hostfwd=... : "user mode" (SLIRP) networking. The guest
#          sits on 10.0.2.0/24 behind a NAT; host port $SSH_PORT on 127.0.0.1
#          is forwarded to the guest's port 22.
###############################################################################
qemu_args() {
    local accel=(-machine type=q35 -cpu max)
    [[ -w /dev/kvm ]] && accel=(-machine type=q35,accel=kvm -cpu host -enable-kvm)
    printf '%s\n' \
        "${accel[@]}" \
        -m "$VM_MEM" \
        -smp "$VM_CPUS" \
        -drive "file=$DISK,if=virtio,format=qcow2,cache=writeback,discard=unmap" \
        -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
        -device virtio-balloon \
        -object rng-random,filename=/dev/urandom,id=rng0 \
        -device virtio-rng-pci,rng=rng0
}

vm_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

step6_run_vm() {
    say "Step 6/7: launching the VM (ssh forwarded to 127.0.0.1:$SSH_PORT)"
    vm_running && { echo "VM already running (pid $(cat "$PIDFILE"))"; return 0; }
    rm -f "$PIDFILE" "$MONITOR"
    mapfile -t ARGS < <(qemu_args)
    qemu-system-x86_64 "${ARGS[@]}" \
        -display none \
        -serial "file:$SERIAL_LOG" \
        -monitor "unix:$MONITOR,server,nowait" \
        -pidfile "$PIDFILE" \
        -daemonize
    echo "qemu pid $(cat "$PIDFILE"); serial console log: $SERIAL_LOG"
}

# Same VM but attached to the current terminal (login on the serial console;
# Ctrl-a x quits QEMU). Handy for debugging the boot.
step6_run_vm_foreground() {
    say "Launching the VM in the foreground (Ctrl-a x to quit)"
    mapfile -t ARGS < <(qemu_args)
    exec qemu-system-x86_64 "${ARGS[@]}" -nographic
}

stop_vm() {
    say "Shutting the VM down"
    if vm_running; then
        # ACPI powerdown via the QEMU monitor, fall back to SIGTERM
        if command -v socat >/dev/null 2>&1; then
            echo system_powerdown | socat - "unix-connect:$MONITOR" >/dev/null || true
        else
            printf 'system_powerdown\n' | timeout 5 \
                python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.sendall(sys.stdin.buffer.read());' \
                "$MONITOR" 2>/dev/null || true
        fi
        for _ in $(seq 1 30); do vm_running || break; sleep 1; done
        vm_running && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$MONITOR"
    echo "stopped"
}

###############################################################################
# Step 7 - wait for sshd and prove that `ssh chenyu@127.0.0.1` works
###############################################################################
step7_wait_and_test_ssh() {
    say "Step 7/7: waiting for the guest sshd on 127.0.0.1:$SSH_PORT"
    local i
    for i in $(seq 1 180); do
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null; then
            echo "port $SSH_PORT open after ${i}s"
            break
        fi
        sleep 1
    done

    # First boot of a fresh image: give sshd/systemd a moment to settle.
    local sshopts=(-p "$SSH_PORT"
                   -o StrictHostKeyChecking=no
                   -o UserKnownHostsFile=/dev/null
                   -o LogLevel=ERROR
                   -o PreferredAuthentications=password
                   -o PubkeyAuthentication=no
                   -o ConnectTimeout=10)
    for i in $(seq 1 30); do
        if sshpass -p "$VM_PASS" ssh "${sshopts[@]}" "$VM_USER@127.0.0.1" \
               'echo "SSH OK: $(whoami)@$(hostname) $(uname -r)"; df -h / | tail -1' 2>/dev/null; then
            say "SUCCESS - connect any time with:"
            echo "    ssh -p $SSH_PORT $VM_USER@127.0.0.1     # password: $VM_PASS"
            return 0
        fi
        sleep 5
    done
    die "could not ssh into the guest; inspect $SERIAL_LOG"
}

do_ssh() {
    exec ssh -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$VM_USER@127.0.0.1"
}

###############################################################################
main() {
    cd "$WORKDIR"
    case "${1:-all}" in
        all)
            step1_install_packages
            step2_download_image
            step3_prepare_disk
            step4_customize_image
            step5_verify_image
            step6_run_vm
            step7_wait_and_test_ssh
            ;;
        prepare)
            step1_install_packages
            step2_download_image
            step3_prepare_disk
            step4_customize_image
            step5_verify_image
            ;;
        run)      step6_run_vm; step7_wait_and_test_ssh ;;
        run-fg)   step6_run_vm_foreground ;;
        ssh)      do_ssh ;;
        stop)     stop_vm ;;
        clean)    stop_vm; rm -f "$DISK" "$SERIAL_LOG"; echo "removed $DISK" ;;
        *)        die "unknown command '$1' (all|prepare|run|run-fg|ssh|stop|clean)" ;;
    esac
}

main "$@"
