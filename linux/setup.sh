#! /bin/bash

VM_NAME=$(sudo virsh list --all --name | grep -i "win")
DIR="$(dirname $(realpath $0))"
BIN_DIR="$HOME/.local/bin"
TARGET="$HOME/.local/share/applications/${VM_NAME}-looking-glass.desktop"
ICON_TARGET="$HOME/.local/share/icons/${VM_NAME}-looking-glass.svg"
LAUNCHER_TARGET="$BIN_DIR/${VM_NAME}_launch"

chmod +x "$DIR"/*.sh

if [[ -f "$TARGET" ]]; then
    read -p "File '$TARGET' already exists. Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 1
    fi
fi

#Installing required packages for each distro
DISTRO=`cat /etc/*release | grep DISTRIB_ID | cut -d '=' -f 2`
FEDORA=`cat /etc/*release |  head -n 1 | cut -d ' ' -f 1`

if [ "$DISTRO" == "Ubuntu" ] || [ "$DISTRO" == "Pop" ] || [ "$DISTRO" == "LinuxMint" ];	then
	sudo apt-get install binutils-dev cmake fonts-freefont-ttf libsdl2-dev libsdl2-ttf-dev libspice-protocol-dev libfontconfig1-dev libx11-dev nettle-dev  wayland-protocols -y
elif [ "$DISTRO" == "Arch" ]; then
	sudo pacman -Syu binutils sdl2 sdl2_ttf libx11 libxpresent nettle fontconfig cmake spice-protocol make pkg-config gcc gnu-free-fonts
elif [ "$DISTRO" == "ArcoLinux" ]; then
	sudo pacman -Syu binutils sdl2 sdl2_ttf libx11 libxpresent nettle fontconfig cmake spice-protocol make pkg-config gcc gnu-free-fonts

elif [ "$DISTRO" == "ManjaroLinux" ]; then
	sudo pacman -Syu binutils sdl2 sdl2_ttf libx11 libxpresent nettle fontconfig cmake spice-protocol make pkg-config gcc gnu-free-fonts
elif [ "$FEDORA" == "Fedora" ]; then
	sudo dnf install cmake gcc gcc-c++ libglvnd-devel fontconfig-devel spice-protocol make nettle-devel \
        pkgconf-pkg-config binutils-devel libXi-devel libXinerama-devel libXcursor-devel \
        libXpresent-devel libxkbcommon-x11-devel wayland-devel wayland-protocols-devel \
        libXScrnSaver-devel libXrandr-devel dejavu-sans-mono-fonts libdecor-devel \
		pipewire-devel libsamplerate-devel
else
	echo "Unsupported distro"
	exit
fi

if ! [[ -x "$(command -v looking-glass-client 2>/dev/null)" ]]; then
	cd $DIR
	wget https://looking-glass.io/artifact/stable/source -O looking_glass.tar.gz
	mkdir -p looking_glass_source && tar -xf looking_glass.tar.gz -C looking_glass_source --strip-components=1
	cd looking_glass_source/ && mkdir -p client/build/ && cd client/build/ && \
		cmake -DCMAKE_INSTALL_PREFIX=~/.local .. && make install
	cd $DIR
	rm -rf ./looking_glass.tar.gz 
fi

mkdir -p "$(dirname "$TARGET")"
mkdir -p "$(dirname "$LAUNCHER_TARGET")"
mkdir -p "$(dirname "$ICON_TARGET")"
cp -f "$DIR/logo.svg" "$ICON_TARGET"
cp -f "$DIR/launch_vm.sh" "$LAUNCHER_TARGET"
cp -f "$DIR/fix_libvirt_nat.sh" "$BIN_DIR/fix-libvirt-nat"
# rsvg-convert -w 48 -h 48 "$ICON" -o "$ICON_TARGET.xmp"
# chmod 777 "$ICON_TARGET.xmp"

# black magic with rev: https://unix.stackexchange.com/a/617832
echo "
[Desktop Entry]
Name=Windows 11
Comment=Launch Windows 11 VM with Looking Glass
Exec=$LAUNCHER_TARGET
Icon=$(realpath $ICON_TARGET |rev| cut -d"." -f2- |rev)
Terminal=false
Type=Application
Categories=System;Emulator;
StartupNotify=true
" | tee $TARGET > /dev/null 2>&1

sudo usermod -aG libvirt,kvm "$(whoami)"
# Passwordless sudo configuration for virsh (optional)
echo "To allow passwordless VM start/shutdown, run:"
echo "sudo EDITOR=vim visudo"
echo "Then add the line:"
echo "$USERNAME ALL=(root) NOPASSWD: /usr/bin/virsh"

sudo mkdir -p /etc/libvirt/hooks/qemu.d/win11 && \
	sudo mkdir -p /etc/libvirt/hooks/qemu.d/win11/prepare/begin && \
	sudo mkdir -p /etc/libvirt/hooks/qemu.d/win11/release/end

sudo cp -f "$DIR/vm_start.sh"			"/etc/libvirt/hooks/qemu.d/win11/prepare/begin/10-asusd-vfio.sh"
sudo cp -f "$DIR/hugepages_start.sh"	"/etc/libvirt/hooks/qemu.d/win11/prepare/begin/20-reserve-hugepages.sh"
sudo cp -f "$DIR/vm_stop.sh"			"/etc/libvirt/hooks/qemu.d/win11/release/end/40-asusd-integrated.sh"
sudo cp -f "$DIR/hugepages_stop.sh"		"/etc/libvirt/hooks/qemu.d/win11/release/end/10-release-hugepages.sh"

sudo chmod +x /etc/libvirt/hooks/qemu.d/win11/prepare/begin/10-asusd-vfio.sh
sudo chmod +x /etc/libvirt/hooks/qemu.d/win11/release/end/40-asusd-integrated.sh
sudo chmod +x /etc/libvirt/hooks/qemu.d/win11/prepare/begin/20-reserve-hugepages.sh
sudo chmod +x /etc/libvirt/hooks/qemu.d/win11/release/end/10-release-hugepages.sh

# update grub driver loading
grep -q 'nvidia_drm.modeset=1' /etc/default/grub || \
	sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 splash rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core nvidia_drm.modeset=1"/' /etc/default/grub
grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub || \
	echo 'GRUB_CMDLINE_LINUX_DEFAULT="splash rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core nvidia_drm.modeset=1"' >> /etc/default/grub

sudo grub2-mkconfig -o /boot/grub2/grub.cfg

sudo usermod -aG libvirt,kvm "$(whoami)"
supergfxctl -m Vfio

echo "Setup complete! You can now launch Windows 11 via your application menu."

