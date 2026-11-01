#!/bin/bash

DIR="$(dirname $(realpath $0))"
VM_NAME=$(virsh -c qemu:///system list --all --name | grep -i "win")

touch /dev/shm/looking-glass && chown "$(whoami)":kvm /dev/shm/looking-glass && chmod 660 /dev/shm/looking-glass

# Logging setup
LOG_DIR="$HOME/.local/share/looking-glass-logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_FILE="$LOG_DIR/${VM_NAME}_lg.log"
# Launch function
launch() {
	$DIR/fix-libvirt-nat
	systemctl --user start pipewire wireplumber
	sudo virsh -c qemu:///system start "$VM_NAME" >/dev/null 2>&1 | tee -a "$LOG_FILE"
	virt-manager &
	# screen -dmS looking_glass \
	looking-glass-client -m KEY_RIGHTCTRL \
		wayland:fractionScale=no \
		win:dontUpscale=yes \
		&> "$LOG_FILE" &
}
# Launch
echo "Launching $VM_NAME at $(date) " | tee -a "$LOG_FILE"
launch
# Wait until VM is running
until sudo virsh -c qemu:///system domstate "$VM_NAME" | grep -q running; do
    echo "Waiting for VM to run..." #| tee -a "$LOG_FILE"
    sleep 1
done
echo "VM $VM_NAME is running." | tee -a "$LOG_FILE"

