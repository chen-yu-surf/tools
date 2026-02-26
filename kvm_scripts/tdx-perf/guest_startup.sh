#!/bin/bash

# need to be added as startup script on the vm guest
# so the host is aware of the guest IP in passthrough mode

# either via crontab -e
# @reboot /path/to/guest_startup.sh
# or via systemctl service by creating a timer in
# /etc/systemd/system/guest_startup.timer

cmdline=$(cat /proc/cmdline)
hostip=$(echo "$cmdline" | grep -oP 'host_ip=\K[^ ]+')
hostpath=$(echo "$cmdline" | grep -oP 'host_path=\K[^ ]+')

# wait for the nic driver to be loaded
sleep 30

if [ -n "$hostip" ] && [ -n "$hostpath" ]; then
	guest_nic=$(ip -o link show | awk -F': ' '$3 ~ /state UP/ && /mq/ {print $2}' | grep -v lo | head -n 1)
	guest_ip=`ip addr show $guest_nic | grep -oP 'inet \K[\d.]+'`
	echo "${guest_ip}" > guest_ip.log
	scp guest_ip.log "root@${hostip}:${hostpath}/"
fi
