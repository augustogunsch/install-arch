#!/bin/sh
set -e

### COLORS ###
RED='\033[0;31m'
LGREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD=$(tput bold)
NORM=$(tput sgr0)

### VARS ###
CURPHASE=1
MAXPHASE=2

### OPTIONS AND PARAMETERS ###

usage() {
	printf "Usage: $0 [-nhv] (-p | [-d] <user>)\n  -p: Install packages only\n  -d: Install dotfiles only\n  -h: Display this message\n  -n: Do not prompt for confirmation\n  -v: Verbose output\n  user: User that the dotfiles should be installed to\n"
	exit 2
}

set_var()
{
	local varname=$1
	shift
	if [ -z "${!varname}" ]; then
		eval "$varname=\"$1\""
	else
		echo "Error: $2 already set"
		usage
	fi
}

exclusive()
{
	echo "Error: $1 exclusive with $2"
	usage
}

while getopts ":nvhdpu:" c; do
	case $c in
		d) 
			[ "$INSTALL" = PACKAGES ] && exclusive '-p' '-d'	
			MAXPHASE=$((MAXPHASE-1))
			set_var INSTALL DOTFILES "-d" ;;
		p) 
			[ "$INSTALL" = DOTFILES ] && exclusive '-p' '-d'
			[ -n "$INSTALLUSER" ] && exclusive '-p' '<user>'
			MAXPHASE=$((MAXPHASE-1))
			set_var INSTALL PACKAGES "-p" ;;
		u) 
			[ "$INSTALL" = PACKAGES ] && exclusive '-p' '<user>'	
			set_var INSTALLUSER $OPTARG "-u" ;;
		n) NOCONFIRM=true ;;
		v) VERBOSE=true ;;
		h) usage ;;
		?) echo "Unknown option -$OPTARG"; usage ;;
	esac
done

INSTALL=${INSTALL:-ALL}
shift $((OPTIND-1))

### VALIDATE USER ###

[ -z "$INSTALLUSER" ] && [ "$INSTALL" != "PACKAGES" ] && echo "Error: <user> required" && usage

if [ -n "$INSTALLUSER" ]; then
	HOMEDIR="$(cat /etc/passwd | awk -F: '$1 ~ /^'$INSTALLUSER'$/ {print $6}')"
	[ -z "$HOMEDIR" ] && echo "Error: User $INSTALLUSER does not exist" && exit 2
fi

### FORCE ROOT ###

[ $(whoami) != "root" ] && echo "Please run as root" && exit 1

### ASK FOR CONFIRMATION ###

if [ ! $NOCONFIRM ]; then
	echo "${BOLD}Please confirm operation:${NORM}"
	echo -ne "Installing ${LGREEN}${INSTALL@L}${NC}"
	[ -n "$INSTALLUSER" ] && echo -ne " for ${LGREEN}$INSTALLUSER ($HOMEDIR)${NC}"
	printf "\n"
	echo -n "Continue installation? [y/N] "
	read ans
	case $ans in
		y|Y) break ;;
		*) exit 0 ;;
	esac
fi

### INSTALLATION ###
[ $VERBOSE ] && set -x

printphase() {
	echo -e "${BOLD}${YELLOW}[$CURPHASE/$MAXPHASE] $1 phase${NC}${NORM}"
	CURPHASE=$((CURPHASE+1))
}

install_aur() {
	dir="$HOMEDIR/$1"
	echo -n "Installing $1... "
	sudo -u "$1" git clone -q "https://aur.archlinux.org/$1.git" "$dir" 2>&1 > /dev/null
	pushd "$dir"
	sudo -u "$1" makepkg -si --noconfirm 2>&1 > /dev/null
	popd
	rm -rf "$1"
	echo "done"
}

remove() {
	echo -n "Removing $1..."
	set +e
	pacman -Rs --noconfirm $1 2>&1 > /dev/null
	set -e
	echo "done"
}

install() {
	echo -n "Installing $1..."
	pacman -Sq --needed --noconfirm $1 2>&1 > /dev/null
	echo "done"
}

prompt() {
	[ $NOCONFIRM ] && return true
	echo -n "$1 [Y/n]"
	read ans
	case $ans in
		n|N) return false ;;
		*) return true ;;
	esac
}

pacman_conf() {
	echo -n "Adding $2 to $1 (/etc/pacman.conf)..."
	awk '$0 ~ /^'$1'[[:blank:]]+=.*[[:blank:]]'$2'[[:blank:]].*/ { exit 0 }' /etc/pacman.conf
	if [ $? = 0 ]; then
		awk '$0 ~ /^'$1'[[:blank:]]+=.*/ { exit 1 }' /etc/pacman.conf
		if [ $? = 1 ]; then
			awk '
			BEGIN { todo = 1 }
			{
				if ($0 ~ /^'$1'[[:blank:]]+=.*/ && todo)
				{
					$(NF+1) = "'$2'"
					todo = 0
				}
				print $0 
			}' \
			/etc/pacman.conf > /tmp/pacman.conf
			mv /tmp/pacman.conf /etc/pacman.conf
		else
			awk '$0 ~ /^#'$1'[[:blank:]]+=[[:blank:]]*$/ { exit 1 } ' /etc/pacman.conf
			if [ $? = 1 ]; then
				awk '
				BEGIN { todo = 1 }
				{
					if ($0 ~ /^#'$1'[[:blank:]]+=[[:blank:]]*$/ && todo)
					{
						$1 = "'$1'"
						$(NF+1) = "'$2'"
						todo = 0
					}
					print $0
				}' \
				/etc/pacman.conf > /tmp/pacman.conf
				mv /tmp/pacman.conf /etc/pacman.conf
			else
				echo "'$1' = $2" >> /etc/pacman.conf
			fi
		fi
	fi
	echo "done"
}

link() {
	echo -n "Linking $2 to $1... "
	ln -sf $1 $2
	echo "done"
}

install_doas() {
	#install_aur requires sudo or doas
	[ ! $(prompt "Do you want to install doas (will remove sudo if installed)?") ] && return
	install sudo
	install_aur doas
	remove sudo
	pacman_conf IgnorePkg sudo
	pacman_conf NoUpgrade sudo
	link /bin/doas /bin/sudo
	echo -n "Configuring doas... "
	echo "permit persist $INSTALLUSER as root" > /etc/doas.conf
	echo "permit nopass $INSTALLUSER as root cmd pacman args -Syu" >> /etc/doas.conf
	echo "permit nopass $INSTALLUSER as root cmd pacman args -Syyu" >> /etc/doas.conf
	echo "done"
}

# PACKAGES
if [ "$INSTALL" != "DOTFILES" ]; then
	printphase "Package installation"
	
	echo -n "Upgrading system... "
	pacman -Sqyu --noconfirm 2>&1 > /dev/null
	echo "done"

	install_doas

	install_aur yay
fi
