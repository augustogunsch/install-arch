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

### URLs ###
DOTFILES="https://github.com/augustogunsch/dotfiles"
PACKAGES_URL="https://raw.githubusercontent.com/augustogunsch/install-arch/master/packages.csv"

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
USER_OUT=""

### DISTRO ###
PACMAN_CONF="/etc/pacman.conf"
PACMAN_TEMP_CONF="/tmp/pacman.conf"
DOAS_CONF="/etc/doas.conf"
DISTRO=$(sed -nE 's/^ID=(.*)/\1/p' < /etc/os-release)
INIT_SYS=$(basename $(readlink /bin/init))
DEFAULT_INCLUDE='/etc/pacman.d/mirrorlist'
if [ "$DISTRO" != "arch" -a "$DISTRO" != "artix" ]; then
	echo "Error: $DISTRO not supported"
	usage
fi
readonly PACMAN_CONF
readonly PACMAN_TEMP_CONF
readonly DOAS_CONF
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
			[ -n "$INSTALL_USER" ] && exclusive '-p' '<user>'
			MAX_PHASE=$((MAX_PHASE-1))
			set_var INSTALL PACKAGES "-p" ;;
		u) 
			[ "$INSTALL" = "PACKAGES" ] && exclusive '-p' '<user>'	
			set_var INSTALL_USER $OPTARG "-u" ;;
		n) NO_CONFIRM=true ;;
		v) VERBOSE=true ;;
		h) usage ;;
		?) echo "Unknown option -$OPTARG"; usage ;;
	esac
done

INSTALL=${INSTALL:-ALL}
shift $((OPTIND-1))

### VALIDATE USER ###

[ -z "$INSTALL_USER" ] && [ "$INSTALL" != "PACKAGES" ] && echo "Error: <user> required" && usage

check_user() {
	HOME_DIR="$(awk -F: '$1 ~ /^'$1'$/ {print $6}' /etc/passwd)"
	[ -z "$HOME_DIR" ] && echo "Error: User $1 does not exist" && return 1
	return 0
}

if [ -n "$INSTALL_USER" ]; then
	set +e
	check_user "$INSTALL_USER"
	[ $? -eq 1 ] && exit 2
	set -e
fi

prompt_user() {
	echo -n "Please type user for whom $1 (leave blank to use same user as with dotfiles or to skip step): "
	local user
	read user
	[ -z "$user" ] && USER_OUT="$INSTALL_USER" && return
	set +e
	USER_OUT="$user"
	check_user "$user"
	[ $? -eq 1 ] && prompt_user "$1" 
	set -e
}

### FORCE ROOT ###

[ $(whoami) != "root" ] && echo "Please run as root" && exit 1

### ASK FOR CONFIRMATION ###

if [ ! $NO_CONFIRM ]; then
	echo "${BOLD}Please confirm operation:${NORM}"
	echo -ne "Installing ${LGREEN}${INSTALL@L}${NC}"
	[ -n "$INSTALL_USER" ] && echo -ne " for ${LGREEN}$INSTALL_USER ($HOME_DIR)${NC}"
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

print_phase() {
	echo -e "${BOLD}${YELLOW}[$CUR_PHASE/$MAX_PHASE] $1 phase${NC}${NORM}"
	CUR_PHASE=$((CUR_PHASE+1))
}

install_aur() {
	[ -z "$INSTALL_USER" ] && return 0
	if [ -z "$2" ]; then
		echo -n "Installing $1 from AUR..."
	else
		echo "Installing $1 from AUR. Description:"
		echo "$2"
	fi
	local dir="$HOME_DIR/$1"
	quiet sudo -u "$INSTALL_USER" git clone -q "https://aur.archlinux.org/$1.git" "$dir"
	qpushd "$dir"
	quiet sudo -u "$INSTALL_USER" makepkg -si --noconfirm
	qpopd
	rm -rf "$dir"
	echo "done"
}

remove() {
	echo -n "Removing $1..."
	set +e
	quiet pacman -Rs --noconfirm $1
	set -e
	echo "done"
}

install() {
	if [ -z "$2" ]; then
		echo -n "Installing $1..."
	else
		echo "Installing $1. Description:"
		echo "$2"
	fi
	set +e
	quiet pacman -Sq --needed --noconfirm $1
	if [ $? -ne 0 ]; then
		set -e
		quiet pacman -Sqyu --needed --noconfirm $1
	fi
	set -e
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

pacman_config() {
	local LABEL=$1
	local OPTION=$2
	local VALUE=$3
	local APPEND=${4:-0} #int
	local LOW_PRIORITY=${5:-0} #int
	local VALUE_ESCAPE=$(echo $VALUE | sed 's|/|\\/|g')

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
	$PACMAN_CONF > $PACMAN_TEMP_CONF

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
		$PACMAN_CONF > $PACMAN_TEMP_CONF

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
			$PACMAN_CONF > $PACMAN_TEMP_CONF

			if [ $? -eq 1 ]; then
				if [ $LOW_PRIORITY -eq 1 ]; then
					cat $PACMAN_CONF > $PACMAN_TEMP_CONF
					echo "" >> $PACMAN_TEMP_CONF
					echo "[$LABEL]" >> $PACMAN_TEMP_CONF
					echo "$OPTION = $VALUE" >> $PACMAN_TEMP_CONF
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
					$PACMAN_CONF > $PACMAN_TEMP_CONF
				fi
			fi
		fi
	fi

	mv $PACMAN_TEMP_CONF $PACMAN_CONF
	set -e
}

pacman_opt() {
	local CONFIG=$1
	local VALUE=$2

	echo -n "Adding $VALUE to $CONFIG [options] ($PACMAN_CONF)..."
	pacman_config options $CONFIG $VALUE 1 0
	echo "done"
}

pacman_repo() {
	local REPO=$1
	local INCLUDE=${2:-$DEFAULT_INCLUDE}

	echo -n "Enabling repository [$REPO] ($PACMAN_CONF)..."
	pacman_config $REPO "Include" $INCLUDE 0 1
	echo "done"
}

link() {
	echo -n "Linking $2 to $1... "
	ln -sf $1 $2
	echo "done"
}

append_line() {
	local FILE=$1
	local LINE=$2
	local LINE_BLANKS="$(echo "$LINE" | sed 's/ /[[:blank:]]+/g')[[:blank:]]*"
	set +e
	awk ' $0 ~ /^'$LINE_BLANKS'$/ { exit 1 } ' "$FILE" > /dev/null
	[ $? -eq 0 ] && echo "$LINE" >> "$FILE"
	set -e
}

configure_doas() {
	[ -e /bin/doas ] || return 0
	echo "Configuring doas..."
	prompt_user 'doas will be configured'
	local DOAS_USER="$USER_OUT"
	if [ -n "$DOAS_USER" ]; then
		append_line $DOAS_CONF "permit persist $DOAS_USER as root"
		append_line $DOAS_CONF "permit nopass $DOAS_USER as root cmd pacman args -Syu"
		append_line $DOAS_CONF "permit nopass $DOAS_USER as root cmd pacman args -Syyu"
	fi
}

install_doas() {
	remove sudo
	install opendoas "Sudo alternative"
	pacman_opt IgnorePkg sudo
	pacman_opt NoUpgrade bin/sudo
	link /bin/doas /bin/sudo
}

install_dash() {
	install dash "Lightweight POSIX shell"
	pacman_opt NoUpgrade bin/sh
	link /bin/dash /bin/sh
}

repos() {
	echo "Detected distro $DISTRO Linux. Proceeding with enabling more repositories."
	if [ "$DISTRO" = "artix" ]; then
		pacman_repo lib32
		local ARCH_REPOS="$DEFAULT_INCLUDE-arch"
		install archlinux-mirrorlist
		pacman_repo extra $ARCH_REPOS
		pacman_repo community $ARCH_REPOS
		pacman_repo multilib $ARCH_REPOS
	else
		pacman_repo multilib
	fi
}

# pwd must be the home dir of the user
configure_vim_for() {
	echo -n "Downloading vim-plug for $1..."
	quiet sudo -u "$1" curl -sfLo .vim/autoload/plug.vim --create-dirs \
	    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
	echo "done"

	echo -n "Installing vim plugins for $1..."
	quiet sudo -u "$1" vim -E -c PlugInstall -c qall
	echo "done"
}

# pwd must be the home dir of the user
install_dotfiles_for() {
	echo -n "Downloading dotfiles for $1 (~/dotfiles)..."
	quiet sudo -u "$1" git clone "$DOTFILES" ./dotfiles
	echo "done"

	echo -n "Linking dotfiles..."
	qpushd "./dotfiles"
	quiet sudo -u "$1" ./install.sh
	echo "done"
	qpopd
}

install_dotfiles() {
	[ "$INSTAL" = "PACKAGES" ] && return 0

	print_phase "Dotfile installation"
	install git

	qpushd "$HOME_DIR"
	install_dotfiles_for "$INSTALL_USER"
	configure_vim_for "$INSTALL_USER"
	qpopd

	qpushd "$HOME"
	install_dotfiles_for "root"
	configure_vim_for "root"
	qpopd

	change_shells
}

install_src() {
	# source code is stored in /root/builds
	qpushd "$HOME"
	local PKG_NAME="$(basename "$1")"
	if [ -z "$2" ]; then
		echo -n "Installing $PKG_NAME from source..."
	else
		echo "Installing $PKG_NAME from source. Description:"
		echo "$2"
	fi
	quiet git clone -q "$1"
	qpushd "$PKG_NAME"
	make
	make install
	qpopd
	qpopd
}

install_loop() {
	[ -f "packages.csv" ] || curl -sL "$PACKAGES_URL" -o "packages.csv"
	while IFS=, read -r method package description; do
		case "$method" in
			"PAC") install "$package" "$description";;
			"AUR") install_aur "$package" "$description";;
			"SRC") install_src "$package" "$description";;
			"FUN") $package ;;
		esac
	done < packages.csv
}

install_packages() {
	[ "$INSTALL" = "DOTFILES" ] && return 0

	print_phase "Package installation"

	echo -n "Upgrading system..."
	quiet pacman -Sqyu --noconfirm
	echo "done"

	install_doas
	install_dash

	install_loop
}

change_shells() {
	echo -n "Configuring zsh..."
	chsh -s /bin/zsh "root"
	chsh -s /bin/zsh "$INSTALL_USER"
	sed 's/^export PROMPT=.*/export PROMPT='"'"'%B%F{166}[%F{172}%n@%m %F{white}%~%F{166}]$%b%f '"'"'/' < "$HOME/.zshrc" > /tmp/zshrc
	mv /tmp/zshrc "$HOME/.zshrc"
	echo "done"
}

main() {
	repos
	install_packages
	install_dotfiles
	configure_doas
}

main
