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
	if [ $? -ne 0 ]; then
		echo "$DUMMY"
		set -e
		return 1
	fi
	set -e
}

ultra_quiet() {
	local DUMMY
	DUMMY=$($@ 2>&1 > /dev/null)
}


### FORCE ROOT ###
[ $(whoami) != "root" ] && echo "Please run as root" && exit 1

### URLs ###
FZF_DOWNLOAD="$(curl -s https://api.github.com/repos/junegunn/fzf/releases/latest | grep linux_amd64 | sed -nE 's/^\s*"browser_download_url":\s*"(.*)"\s*$/\1/p')"
PARTED_DOWNLOAD="https://archlinux.org/packages/extra/x86_64/parted/download"
POST_INSTALL_SCRIPT="https://raw.githubusercontent.com/augustogunsch/install-arch/master/post-install.sh"

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
MAX_PHASE=4

### INFO ###
AVAILABLE_PLATFORMS='Both BIOS and UEFI systems\nOnly x86_64 systems\nDistros:\nArch\nArtix (OpenRC)\n'
readonly AVAILABLE_PLATFORMS

echo "This script can only be run interactively. Make sure you are in a supported platform and have an Internet connection. Available platforms:"
echo -e "$AVAILABLE_PLATFORMS"

### SYSTEM ###
DISTRO=$(cat /etc/os-release | sed -nE 's/^ID=(.*)/\1/p')
INIT_SYS=$(basename $(readlink /bin/init))
set +e
ultra_quiet ls /sys/firmware/efi/efivars
[ $? -eq 0 ] && UEFI=1 || UEFI=0
set -e
readonly DISTRO
readonly INIT_SYS
readonly UEFI

right_chroot() {
	[ "$DISTRO" = "arch" ] && arch-chroot $@ || artix-chroot $@
}

right_fstabgen() {
	[ "$DISTRO" = "arch" ] && genfstab $@ || fstabgen $@
}

right_basestrap() {
	[ "$DISTRO" = "arch" ] && pacstrap $@ || basestrap $@
}

print_phase() {
	echo -e "${BOLD}${YELLOW}[$CUR_PHASE/$MAX_PHASE] $1 phase${NC}${NORM}"
	CUR_PHASE=$((CUR_PHASE+1))
}

download_fzf() {
	echo -n "Downloading fzf (for script use only)..."
	curl -sL "$FZF_DOWNLOAD" -o fzf.tar.gz
	tar -xf fzf.tar.gz
	mv ./fzf /usr/bin/fzf
	rm fzf.tar.gz
	echo "done"
}

download_parted() {
	echo -n "Downloading parted (for script use only)..."
	curl -sL "$PARTED_DOWNLOAD" -o parted.tar.zst
	tar -xf parted.tar.zst
	cp -r ./usr /
	rm -r ./usr
	rm parted.tar.zst
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
	[ -f /bin/parted ] || download_parted

	local rootN

	echo -n "Partitioning drive..."
	if [ $UEFI -eq 0 ]; then
	# Legacy
		rootN=2
		parted --script "$DRIVE_TARGET" \
		mklabel msdos \
		mkpart primary linux-swap 0% 4GiB \
		mkpart primary ext4 4GiB 100%
		echo "done"
	else
	# EFI
		rootN=3
		parted --script "$DRIVE_TARGET" \
		mklabel gpt \
		mkpart swap linux-swap 0% 4GiB \
		mkpart boot fat32 4GiB 5Gib \
		mkpart root ext4 5GiB 100% \
		set 2 esp on
		echo "done"

		echo -n "Configuring BOOT partition..."
		quiet mkfs.fat -F 32 "$DRIVE_TARGET"2
		fatlabel "$DRIVE_TARGET"2 BOOT
		mkdir /mnt/boot
		mount "$DRIVE_TARGET"2 /mnt/boot
		echo "done"
	fi

	echo -n "Configuring SWAP partition..."
	quiet mkswap -L SWAP "$DRIVE_TARGET"1
	quiet swapon "$DRIVE_TARGET"1
	echo "done"

	echo -n "Configuring ROOT partition..."
	quiet mkfs.ext4 -L ROOT "$DRIVE_TARGET"$rootN
	quiet mount "$DRIVE_TARGET"$rootN /mnt
	echo "done"
}

install_base() {
	print_phase "System installation"
	echo -n "Installing base system, kernel, bootloader and vi..."
	quiet right_basestrap /mnt base base-devel linux linux-firmware grub vi
	echo "done"

	if [ "$DISTRO" = "artix" ]; then
		if [ "$INIT_SYS" = "openrc-init" ]; then
			echo -n "Installing openrc..."
			quiet right_basestrap /mnt openrc elogind-openrc
			echo "done"
		else	
			echo
			echo "Error: Unsupported init system \"$INIT_SYS\""
			exit 1
		fi
	elif [ "$DISTRO" != "arch" ]; then
		echo "Error: Unsupported distro \"$DISTRO\""
	fi

	echo -n "Generating fstab..."
	right_fstabgen -U /mnt >> /mnt/etc/fstab
	echo "done"
}

set_timezone() {
	ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime
	quiet right_chroot /mnt hwclock --systohc
}

set_locale() {
	echo -n "Configuring locale..."
	cat /mnt/etc/locale.gen | sed "s/^#$LOCALE/$LOCALE/" > /tmp/locale.gen
	mv /tmp/locale.gen /mnt/etc/locale.gen
	quiet right_chroot /mnt locale-gen

	echo "export LANG=\"en_US.UTF-8\"" > /mnt/etc/locale.conf
	echo "export LC_COLLATE=\"C\"" >> /mnt/etc/locale.conf
	echo "done"
}

setup_grub() {
	echo -n "Configuring boot loader..."
	if [ $UEFI -eq 1 ]; then
		quiet right_chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
	else
		quiet right_chroot /mnt grub-install --target=i386-pc "$DRIVE_TARGET"
	fi
	quiet right_chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
	echo "done"
}

setup_users() {
	echo -n "Configuring users..."

	set +e
	# There might be a group with the user's name
	awk -F: '$1 ~ /^'$PERSONAL_USER'$/ { exit 1 }' /etc/group
	[ $? -eq 0 ] && right_chroot /mnt useradd --badnames -m "$PERSONAL_USER" || \
		right_chroot /mnt useradd --badnames -m -g "$PERSONAL_USER" "$PERSONAL_USER"
	set -e

	echo -e "root:$ROOT_PASSWORD\n$PERSONAL_USER:$PERSONAL_PASSWORD" | chpasswd -R /mnt
	echo "done"
}

setup_network() {
	echo -n "Configuring hostname and network..."
	echo "$MACHINE_HOSTNAME" > /mnt/etc/hostname
	echo "127.0.0.1	localhost" > /mnt/etc/hosts
	echo "::1	localhost" >> /mnt/etc/hosts
	echo "127.0.1.1	$MACHINE_HOSTNAME.localdomain	$MACHINE_HOSTNAME" >> /mnt/etc/hosts

	quiet right_basestrap /mnt dhcpcd wpa_supplicant
	if [ "$DISTRO" = "artix" ]; then
		if [ "$INIT_SYS" = "openrc-init" ]; then
			echo "hostname=\"$MACHINE_HOSTNAME\"" > /mnt/etc/conf.d/hostname
			quiet right_basestrap /mnt connman-openrc
			quiet right_chroot /mnt rc-update add connmand
		fi
	else
		quiet right_chroot /mnt systemctl enable dhcpcd
	fi
	echo "done"
}

ask_password() {
	echo -n "Type password for $1: "
	stty -echo
	read USER_PASSWORD
	stty echo
	echo
	echo -n "Confirm password: "
	stty -echo
	local PASSWORD_CONFIRM
	read PASSWORD_CONFIRM
	stty echo
	echo
	if [ "$USER_PASSWORD" != "$PASSWORD_CONFIRM" ]; then
		echo "Wrong passwords. Please try again."
		ask_password $1
	fi
}

prompt_all() {
	download_fzf

	prompt_drive

	echo "Choose timezone:"
	qpushd /usr/share/zoneinfo
	TIMEZONE="$(fzf --layout=reverse --height=20)"
	qpopd

	echo "Choose locale:"
	LOCALE=$(cat /etc/locale.gen | sed '/^#\s/D' | sed '/^#$/D' | sed 's/^#//' | fzf --layout=reverse --height=20)

	ask_password root
	ROOT_PASSWORD="$USER_PASSWORD"

	echo -n "Type your personal username: "
	read PERSONAL_USER
	ask_password "$PERSONAL_USER"
	PERSONAL_PASSWORD="$USER_PASSWORD"

	echo -n "Type the machine hostname: "
	read MACHINE_HOSTNAME
}

post_install() {
	curl -sL "$POST_INSTALL_SCRIPT" -o post-install.sh
	mv post-install.sh /mnt/root
	chmod +x /mnt/root/post-install.sh
	echo -n "Ready for post-install script. Press any key to continue..."
	read dummy
	print_phase "Post installation"
	right_chroot /mnt /root/post-install.sh -nu "$PERSONAL_USER"
}

configure() {
	print_phase "System configuration"

	set_timezone
	set_locale
	setup_grub
	setup_users
	setup_network
}

main() {
	prompt_all
	partition
	install_base
	configure
	post_install

	umount -R /mnt
	echo -n "Ready to reboot. Press any key to continue..."
	read dummy
	reboot
}

main
