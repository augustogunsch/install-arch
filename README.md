Bash scripts for installing Arch/Artix Linux. `install.sh` installs the whole system from scratch and then calls `post-install.sh`. If you prefer, you may install the system manually (or in an existing installation) and run `post-install.sh` alone. There is no need to clone the repository, as each script can download missing files.

# Quick install
```curl https://raw.githubusercontent.com/augustogunsch/install-arch/master/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

# Supported platforms
## System
- UEFI and BIOS
- x86_64 architecture
## Distros
- Arch Linux
- Artix Linux
## Init systems
- systemd
- openrc

# List of Packages
See `packages.csv`

# Features
## install.sh
- Partitions the chosen drive
- Installs core packages, bootloader, etc
- Sets the chosen locale, keyboard layout (both for X11 and the console) and time zone
- Sets up the root user and an additional personal user
- Sets the network configuration up
## post-install.sh
- Enables additional pacman repositories
- Links `/bin/sh` to `/bin/dash`
- Installs OpenBSD's `doas` and sets it as default, as opposed to `sudo`
- Optionally gives a user root privileges through `doas`
- Installs every package in `packages.csv`
- Installs `vim` and its plugins for root and a user
- Installs my dotfiles for root and a user
- Many of these can be turned off via CLI arguments
