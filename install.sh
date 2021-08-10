#!/bin/sh
set -e

qpushd() {
	pushd $@ > /dev/null
}

qpopd() {
	popd $@ > /dev/null
}

quiet() {
	local DUMMY
	set +e
	DUMMY=$($@ 2>&1 > /dev/null)
	set -e
}


### FORCE ROOT ###
[ $(whoami) != "root" ] && echo "Please run as root" && exit 1

### URLs ###
FZF_DOWNLOAD="$(curl -s https://api.github.com/repos/junegunn/fzf/releases/latest | grep linux_amd64 | sed -nE 's/^\s*"browser_download_url":\s*"(.*)"\s*$/\1/p')"
PARTED_DOWNLOAD="https://archlinux.org/packages/extra/x86_64/parted/download"

### COLORS ###
RED='\033[0;31m'
LGREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD=$(tput bold)
NORM=$(tput sgr0)
readonly RED
readonly LGREEN
readonly YELLOW
readonly NC
readonly BOLD
readonly NORM

### VARS ###
CUR_PHASE=1
MAX_PHASE=3

### INFO ###
AVAILABLE_PLATFORMS='Arch\nArtix (OpenRC)\n'
readonly AVAILABLE_PLATFORMS

echo "This script can only be run interactively. Make sure you are in a supported platform and have an Internet connection. Available platforms:"
echo -e "$AVAILABLE_PLATFORMS"

### SYSTEM ###
DISTRO=$(cat /etc/os-release | sed -nE 's/^ID=(.*)/\1/p')
INIT_SYS=$(basename $(readlink /bin/init))
quiet ls /sys/firmware/efi/efivars
[ $? -eq 0 ] && UEFI=1 || UEFI=0
readonly DISTRO
readonly INIT_SYS
readonly UEFI

print_phase() {
	echo -e "${BOLD}${YELLOW}[$CUR_PHASE/$MAX_PHASE] $1 phase${NC}${NORM}"
	CUR_PHASE=$((CUR_PHASE+1))
}

download_fzf() {
	echo -n "Downloading fzf (for script use only)..."
	curl -sL "$FZF_DOWNLOAD" -o fzf.tar.gz
	tar -xf fzf.tar.gz
	alias fzf="./fzf"
	echo "done"
}

download_parted() {
	echo -n "Downloading parted (for script use only)..."
	curl -sL "$PARTED_DOWNLOAD" -o parted.tar.xz
	tar -xf parted.tar.xz
	cp ./usr/bin/parted .
	alias parted="./parted"
	echo "done"
}

prompt() {
	echo -n "$1 [Y/n] "
	[ $NO_CONFIRM ] && echo "y" && return 1
	read ans
	case $ans in
		n|N) return 0 ;;
		*) return 1 ;;
	esac
}

prompt_drive() {
	local DRIVES="$(lsblk -pno NAME,TYPE,MODEL | awk 'BEGIN {count=1} $1 ~ /^\// { 
		if ($2 == "disk") {printf("%i'")"' %s    \"", count, $1); for(i=3;i<NF;i++) printf("%s ", $i); printf("%s\"\n", $NF); count++ } }')" 
	echo "Available drives:"
	printf "   %-12s %s\n" "DISK" "IDENTIFIER"
	echo -e "$DRIVES" 
	echo -n "Choose drive to install $DISTRO into (WARNING: it will be repartitioned and wiped out) (default=1): "
	local drive
	read drive

	[ -z "$drive" ] && drive=1
	DRIVE_TARGET=$(echo -e "$DRIVES" | awk '$1 ~ /^'$drive'\)$/ { print $2 }')
	if [ -z "$DRIVE_TARGET" ]; then
		echo "Invalid target"
		exit 1
	fi

	set +e
	prompt "Installing to $DRIVE_TARGET. Confirm?"
	[ $? -eq 0 ] && exit 0
	set -e
}

partition() {
	print_phase "Disk partitioning"
	[ -e /bin/parted ] || download_parted
	prompt_drive

	echo -n "Partitioning drive..."
	parted --script "$DRIVE_TARGET" \
	mklabel gpt \
	mkpart swap ext4 1MiB 4GiB \
	mkpart boot ext4 4GiB 5Gib \
	mkpart root ext4 5GiB 100%
	echo "done"

	echo -n "Configuring SWAP partition..."
	quiet mkswap -L SWAP "$DRIVE_TARGET"1
	quiet swapon "$DRIVE_TARGET"1
	echo "done"

	echo -n "Configuring ROOT partition..."
	quiet mkfs.ext4 -L ROOT "$DRIVE_TARGET"3
	quiet mount "$DRIVE_TARGET"3 /mnt
	echo "done"

	echo -n "Configuring BOOT partition..."
	if [ $UEFI -eq 1 ]; then
		quiet mkfs.fat -F 32 "$DRIVE_TARGET"2
		fatlabel "$DRIVE_TARGET"2 BOOT
	else
		quiet mkfs.ext4 -L BOOT "$DRIVE_TARGET"2
	fi
	mkdir /mnt/boot
	mount "$DRIVE_TARGET"2 /mnt/boot
	echo "done"
}

install_base() {
	print_phase "System installation"
	echo -n "Installing base system, kernel, bootloader and vi..."

	if [ "$DISTRO" = "artix" ]; then
		quiet basestrap /mnt base base-devel linux linux-firmware grub vi
		echo "done"
		if [ "$INIT_SYS" = "openrc-init" ]; then
			echo -n "Installing openrc..."
			quiet basestrap /mnt openrc elogind-openrc
			echo "done"
		else	
			echo
			echo "Error: Unsupported init system \"$INIT_SYS\""
			exit 1
		fi
		echo -n "Generating fstab..."
		fstabgen -U /mnt >> /mnt/etc/fstab
		echo "done"

	elif [ "$DISTRO" = "arch" ]; then
		quiet pacstrap /mnt base linux linux-firmware grub vi
		echo "done"
		echo -n "Generating fstab..."
		genfstab -U /mnt >> /mnt/etc/fstab
		echo "done"
	else
		echo
		echo "Error: Unsupported distro."
		exit 1
	fi
}

set_timezone() {
	echo "Choose timezone:"
	qpushd /mnt/usr/share/zoneinfo
	ln -sf "/mnt/usr/share/zoneinfo/$(fzf --layout=reverse --height=20)" /mnt/etc/localtime
	qpopd
	[ "$DISTRO" = "arch" ] && alias chroot="arch-chroot"
	quiet chroot /mnt hwclock --systohc
}

set_locale() {
	echo "Choose locale:"
	local LOCALE=$(cat /mnt/etc/locale.gen | sed '/^#\s/D' | sed '/^#$/D' | sed 's/^#//' | fzf --layout=reverse --height=20)

	echo -n "Configuring locale..."
	cat /mnt/etc/locale.gen | sed "s/^#$LOCALE/$LOCALE/" > /tmp/locale.gen
	mv /tmp/locale.gen /mnt/etc/locale.gen
	quiet chroot /mnt locale-gen

	echo "export LANG=\"en_US.UTF-8\"" > /mnt/etc/locale.conf
	echo "export LC_COLLATE=\"C\"" >> /mnt/etc/locale.conf
	echo "done"
}

setup_grub() {
	echo -n "Configuring boot loader..."
	if [ $UEFI -eq 1 ]; then
		quiet chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --botloader-id=grub
	else
		quiet chroot /mnt grub-install "$DRIVE_TARGET"
	fi
	quiet chroot grub-mkconfig -o /boot/grub/grub.cfg
	echo "done"
}

setup_users() {
	echo "Type root password:"
	chroot /mnt passwd -q

	echo -n "Type your personal username: "
	local user
	read user
	chroot /mnt useradd -m "$user"
	echo "Type your password:"
	chroot /mnt passwd -q "$user"
}

setup_network() {
	echo -n "Type the machine hostname: "
	local hostname
	read hostname

	echo -n "Configuring hostname and network..."
	echo "$hostname" > /mnt/etc/hostname
	echo "127.0.0.1	localhost" > /mnt/etc/hosts
	echo "::1	localhost" >> /mnt/etc/hosts
	echo "127.0.1.1	$hostname.localdomain	$hostname" >> /mnt/etc/hosts

	if [ "$DISTRO" = "artix" ]; then
		if [ "$INIT_SYS" = "openrc-init" ]; then
			echo "hostname=\"$hostname\"" > /mnt/etc/conf.d/hostname
			quiet chroot pacman -S connman-openrc
			quiet chroot rc-update add connmand
		fi
		quiet chroot pacman -S dhcpcd wpa_supplicant
	fi
	echo "done"
}

configure() {
	print_phase "System configuration"
	download_fzf

	set_timezone
	set_locale
	setup_grub
	setup_users
	setup_network

	umount -R /mnt
	echo -n "Ready to reboot. Press any key to continue..."
	read dummy
	reboot
}

main() {
	partition
	install_base
	configure
}

main
