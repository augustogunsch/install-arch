#!/bin/sh
set -e

ask_root() {
	if [ "$(whoami)" != "root" ]; then
		echo "Please run as root."
		exit 1
	fi
}

quiet() {
	local DUMMY
	set +e
	DUMMY=$($@ 2>&1 > /dev/null)
	set -e
}

#ask_root

DISTRO=$(lsb_release -is)
INIT_SYS=$(basename $(readlink /bin/init))

quiet ls /sys/firmware/efi/efivars
[ $? -eq 0 ] && UEFI=1 || UEFI=0

AVAILABLE_PLATFORMS='Artix (OpenRC)\n'
readonly AVAILABLE_PLATFORMS

install() {
	echo -n "Installing $1..."
	pacman -Sq --needed --noconfirm $1 2>&1 > /dev/null
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
	prompt "Installing for $DRIVE_TARGET. Confirm?"
	[ $? -eq 0 ] && exit 0
	set -e
}

partition() {
	prompt_drive

	echo -n "Partitioning drive..."
	parted --script "$DRIVE_TARGET" \
	mklabel gpt \
	mkpart swap ext4 0MiB 4GiB \
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
		quiet mkfs.fat32 "$DRIVE_TARGET"2
		fatlabel "$DRIVE_TARGET"2 BOOT
	else
		quiet mkfs.ext4 -L BOOT "$DRIVE_TARGET"2
	fi
	mkdir /mnt/boot
	mount "$DRIVE_TARGET"2 /mnt/boot
	echo "done"
}

main() {
	prompt_drive
	echo "$DRIVE_TARGET"
}

main
