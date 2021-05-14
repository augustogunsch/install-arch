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
			MAXPHASE=$(($MAXPHASE-1))
			set_var INSTALL DOTFILES "-d" ;;
		p) 
			[ "$INSTALL" = DOTFILES ] && exclusive '-p' '-d'
			[ -n "$INSTALLUSER" ] && exclusive '-p' '<user>'
			MAXPHASE=$(($MAXPHASE-1))
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
	CURPHASE=$(($CURPHASE+1))
}

# PACKAGES
if [ "$INSTALL" != "DOTFILES" ]; then
	printphase "Package installation"
	
	echo -n "Upgrading system... "
	_DUMMY=$(pacman -Sqyu --noconfirm 2>&1 > /dev/null)
	echo "done"
fi
