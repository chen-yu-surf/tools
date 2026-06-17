#!/bin/bash
# start_div_zero.sh - Build kernel, deploy to VM, trigger divide-by-zero test
#
# Workflow:
#   1. Run compile.sh to build/install new kernel (VM shuts down due to -no-reboot)
#   2. Relaunch VM with setup_img_launch_vm.sh launch
#   3. Copy trigger_div_zero.sh to VM and execute it
#   4. Monitor serial port for divide-by-zero
#   5. On detection: save serial log to dbz.log, kill QEMU, relaunch VM

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ROOT_PASSWORD=123456
GUEST_IP=localhost
SSH_PORT=2222
SERIAL_LOG="$SCRIPT_DIR/vm_serial.log"

ssh_vm() {
    sshpass -p "$ROOT_PASSWORD" ssh -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@"$GUEST_IP" "$@"
}

scp_vm() {
    sshpass -p "$ROOT_PASSWORD" scp -P "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$@"
}

wait_vm_shutdown() {
    echo "=== Waiting for VM to shut down ==="
    local max_wait=300
    local elapsed=0
    while pgrep -f 'process=genvm' >/dev/null 2>&1; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $elapsed -ge $max_wait ]; then
            echo "ERROR: VM did not shut down within ${max_wait}s"
            exit 1
        fi
        echo "  waiting for shutdown... (${elapsed}s / ${max_wait}s)"
    done
    echo "VM has shut down."
}

# === Step 1: Ensure VM is running (compile.sh needs SSH access) ===
echo "=========================================="
echo "Step 1: Ensure VM is running"
echo "=========================================="
if ! pgrep -f 'process=genvm' >/dev/null 2>&1; then
    echo "No VM running, launching one first..."
    ./setup_img_launch_vm.sh launch
fi

# === Step 2: Compile and install new kernel ===
echo "=========================================="
echo "Step 2: Build and install new kernel"
echo "=========================================="
./compile.sh

# === Step 3: Wait for VM to shut down (due to -no-reboot) ===
wait_vm_shutdown
sleep 2

# === Step 4: Relaunch VM with new kernel ===
echo "=========================================="
echo "Step 4: Relaunch VM with new kernel"
echo "=========================================="
./setup_img_launch_vm.sh launch

# === Step 5: Copy trigger_div_zero.sh to VM ===
echo "=========================================="
echo "Step 5: Copy trigger_div_zero.sh to VM"
echo "=========================================="
scp_vm "$SCRIPT_DIR/flat_test/trigger_div_zero.sh" root@"$GUEST_IP":~/trigger_div_zero.sh
ssh_vm "chmod +x ~/trigger_div_zero.sh"

# === Step 6: Launch trigger_div_zero.sh on VM (background) ===
echo "=========================================="
echo "Step 6: Launch trigger_div_zero.sh on VM"
echo "=========================================="
ssh_vm "nohup ~/trigger_div_zero.sh > ~/div_zero_output.log 2>&1 &"
echo "trigger_div_zero.sh is running on VM."

# === Step 7: Monitor serial port for divide-by-zero ===
echo "=========================================="
echo "Step 7: Monitoring serial port for divide-by-zero"
echo "=========================================="
echo "Watching: $SERIAL_LOG"

while true; do
    if grep -qi "divide.error\|divide-by-zero\|divide_error\|division by zero" "$SERIAL_LOG" 2>/dev/null; then
        echo ""
        echo "*** Divide-by-zero detected in VM serial output! ***"

        # Save serial log
        cp "$SERIAL_LOG" "$SCRIPT_DIR/dbz.log"
        echo "Serial log saved to: $SCRIPT_DIR/dbz.log"

        # Kill QEMU
        QEMU_PID=$(pgrep -f 'process=genvm' 2>/dev/null || true)
        if [ -n "$QEMU_PID" ]; then
            echo "Killing QEMU (PID: $QEMU_PID) with kill -9"
            kill -9 $QEMU_PID
            sleep 2
        fi

        break
    fi

    # Check if QEMU is still running (VM might have crashed or test finished)
    if ! pgrep -f 'process=genvm' >/dev/null 2>&1; then
        echo "WARNING: QEMU process exited before divide-by-zero was detected."
        echo "The test may have completed without triggering the bug."
        cp "$SERIAL_LOG" "$SCRIPT_DIR/dbz.log"
        echo "Serial log saved to: $SCRIPT_DIR/dbz.log"
        break
    fi

    sleep 2
done

# === Step 8: Relaunch VM ===
echo "=========================================="
echo "Step 8: Relaunch VM"
echo "=========================================="
./setup_img_launch_vm.sh launch

echo "=========================================="
echo "Done. VM is running again."
echo "Divide-by-zero serial log: $SCRIPT_DIR/dbz.log"
echo "=========================================="
