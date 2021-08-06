#!/bin/sh
set -e

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
MAX_PHASE=2
readonly MAX_PHASE

### DISTRO ###
PACMAN_PATH="/etc/pacman.conf"
PACMAN_TEMP_PATH="/tmp/pacman.conf"
DISTRO=$(lsb_release -is)
DEFAULT_INCLUDE='/etc/pacman.d/mirrorlist'
if [ "$DISTRO" != "Arch" -a "$DISTRO" != "Artix" ]; then
	echo "Error: $(lsb_release -ds) not supported"
	usage
fi
readonly PACMAN_PATH
readonly PACMAN_TEMP_PATH
readonly DISTRO
readonly DEFAULT_INCLUDE

### OPTIONS AND PARAMETERS ###

usage() {
	printf "Usage: $0 [-nhv] (-p | [-d] -u <user>)\n  -p: Install packages only\n  -d: Install dotfiles only\n  -h: Display this message\n  -n: Non-interactive mode\n  -v: Verbose output\n  -u <user>: User that the dotfiles should be installed to\n"
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
			[ "$INSTALL" = "PACKAGES" ] && exclusive '-p' '-d'	
			MAX_PHASE=$((MAX_PHASE-1))
			set_var INSTALL DOTFILES "-d" ;;
		p) 
			[ "$INSTALL" = "DOTFILES" ] && exclusive '-p' '-d'
			[ -n "$INSTALLUSER" ] && exclusive '-p' '<user>'
			MAX_PHASE=$((MAX_PHASE-1))
			set_var INSTALL PACKAGES "-p" ;;
		u) 
			[ "$INSTALL" = "PACKAGES" ] && exclusive '-p' '<user>'	
			set_var INSTALLUSER $OPTARG "-u" ;;
		n) NO_CONFIRM=true ;;
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

if [ ! $NO_CONFIRM ]; then
	echo "${BOLD}Please confirm operation:${NORM}"
	echo -ne "Installing ${LGREEN}${INSTALL@L}${NC}"
	[ -n "$INSTALLUSER" ] && echo -ne " for ${LGREEN}$INSTALLUSER ($HOMEDIR)${NC}"
	printf "\n"
	echo -n "Proceed with installation? [y/N] "
	read ans
	case $ans in
		y|Y) break ;;
		*) exit 0 ;;
	esac
fi

### INSTALLATION ###
[ $VERBOSE ] && set -x

printphase() {
	echo -e "${BOLD}${YELLOW}[$CUR_PHASE/$MAX_PHASE] $1 phase${NC}${NORM}"
	CUR_PHASE=$((CUR_PHASE+1))
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
	[ $NO_CONFIRM -eq 1 ] && return true
	echo -n "$1 [Y/n]"
	read ans
	case $ans in
		n|N) return false ;;
		*) return true ;;
	esac
}

pacman_config() {
	local LABEL=$1
	local OPTION=$2
	local VALUE=$3
	local APPEND=${4:-0} #int
	local LOW_PRIORITY=${5:-0} #int
	local VALUE_ESCAPE=$(echo $VALUE | sed 's/\//\\\//g')

# 1st script
#	if(there is [LABEL] uncommented):
#		if(there is OPTION uncommented):
#			if(VALUE != CURRENT_VALUE):
#				if(APPEND):
#					append(VALUE);
#				else:
#					substitute(CURRENT_VALUE,VALUE);
# 2nd script
#		else if(there is OPTION = VALUE commented):
#			uncomment(OPTION = VALUE);
# 3rd script
#	else if(there is [LABEL] commented):
#		uncomment(LABEL);
#		if(there is OPTION = VALUE commented):
#			uncomment(OPTION = VALUE);
#		else:
#			append(OPTION = VALUE);
# 4th script
#	else:
#		append([LABEL]);
#		append(OPTION = VALUE);

	set +e
	awk '
	BEGIN { todo = 1 }
	{ if ($0 ~ /^\['$LABEL'\][[:blank:]]*$/) {
		print $0

		while(1) {
			hasline = getline
			if (!hasline || $0 ~ /^\[.*\][[:blank:]]*$/) {
				break
			}
			else if ($0 ~ /^'$OPTION'[[:blank:]]+=.*/) {
				todo = 0
				if ($0 !~ /[[:blank:]]'$VALUE_ESCAPE'/) {
					if('$APPEND') {$(NF+1) = "'$VALUE'"}
					else {$3 = "'$VALUE'"; NF = 3}
				}
				print $0
				break
			}
			print $0
		}
	} else {
		print $0
	} } 
	END { exit todo } ' \
	$PACMAN_PATH > $PACMAN_TEMP_PATH

	if [ $? -eq 1 ]; then
		awk '
		BEGIN { todo = 1 }
		{ if ($0 ~ /^\['$LABEL'\][[:blank:]]*$/) {
			print $0

			while(1) {
				hasline = getline
				if (!hasline || $0 ~ /^\[.*\][[:blank:]]*$/) {
					break
				}
				if ($0 ~ /^#?'$OPTION'[[:blank:]]+=.*[[:blank:]]'$VALUE_ESCAPE'/) {
					todo = 0
					$1 = "'$OPTION'"
					print $0
					break
				}
				print $0
			}
		} else {
			print $0
		} } 
		END { exit todo } ' \
		$PACMAN_PATH > $PACMAN_TEMP_PATH

		if [ $? -eq 1 ]; then
			awk '
			BEGIN { todo = 1 }
			{ if ($0 ~ /^#?\['$LABEL'\][[:blank:]]*$/) {
				todo = 0
				print "['$LABEL']"

				while(1) {
					hasline = getline
					if (!hasline || $0 ~ /^\[.*\][[:blank:]]*$/) {
						print "'$OPTION' = '$VALUE'"
						print ""
						print $0
						break
					}
					if ($0 ~ /^#?'$OPTION'[[:blank:]]+=.*[[:blank:]]'$VALUE_ESCAPE'/) {
						$1 = "'$OPTION'"
						print $0
						break
					}
					print $0
				}
			} else {
				print $0
			} } 
			END { exit todo } ' \
			$PACMAN_PATH > $PACMAN_TEMP_PATH

			if [ $? -eq 1 ]; then
				if [ $LOW_PRIORITY -eq 1 ]; then
					cat $PACMAN_PATH > $PACMAN_TEMP_PATH
					echo "" >> $PACMAN_TEMP_PATH
					echo "[$LABEL]" >> $PACMAN_TEMP_PATH
					echo "$OPTION = $VALUE" >> $PACMAN_TEMP_PATH
				else
					awk '
					BEGIN { todo = 1 }
					{
						if (todo && $0 ~ /^#?\[.*\][[:blank:]]*$/) {
							print "['$LABEL']"
							print "'$OPTION' = '$VALUE'"
							print ""
							todo = 0
						}
						print $0
					}

					END {
						if (todo) {
							print ""
							print "['$LABEL']"
							print "'$OPTION' = '$VALUE'"
						}
					} ' \
					$PACMAN_PATH > $PACMAN_TEMP_PATH
				fi
			fi
		fi
	fi

	mv $PACMAN_TEMP_PATH $PACMAN_PATH
	set -e
}

pacman_opt() {
	local CONFIG=$1
	local VALUE=$2

	echo -n "Adding $VALUE to $CONFIG (/etc/pacman.conf)..."
	pacman_config options $CONFIG $VALUE 1 0
	echo "done"
}

pacman_repo() {
	local REPO=$1
	local INCLUDE=${2:-$DEFAULT_INCLUDE}

	echo -n "Enabling repository [$REPO] (/etc/pacman.conf)..."
	pacman_config $REPO "Include" $INCLUDE 0 1
	echo "done"
}

link() {
	echo -n "Linking $2 to $1... "
	ln -sf $1 $2
	echo "done"
}

install_doas() {
	#install_aur requires sudo or doas
	[ ! $(prompt "Do you want to install doas (will remove sudo and forbid it in /etc/pacman.conf)?") ] && return
	install sudo
	install_aur doas
	remove sudo
	pacman_opt IgnorePkg sudo
	pacman_opt NoUpgrade sudo
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
