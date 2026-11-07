#!/bin/bash

set -ouex pipefail

### Install packages

# The base is ublue-os/base-main: Fedora Atomic with no desktop. It already
# has NetworkManager, PipeWire/WirePlumber, bluez, polkit, flatpak (with the
# Flathub remote), podman, distrobox and just. Add the Niri session and the
# few desktop pieces GNOME used to provide.
dnf5 install -y \
    niri \
    xdg-desktop-portal-gnome \
    xdg-desktop-portal-gtk \
    gnome-keyring \
    gnome-keyring-pam \
    nautilus \
    xdg-user-dirs \
    tuned-ppd \
    playerctl \
    mesa-dri-drivers \
    mesa-libGL \
    mesa-libEGL \
    mesa-vulkan-drivers \
    vulkan-loader \
    wayland-utils \
    swaybg \
    swayidle \
    swaylock \
    foot \
    lxpolkit \
    python3 \
    jetbrains-mono-fonts-all \
    google-noto-sans-fonts \
    google-noto-sans-mono-fonts \
    google-noto-emoji-fonts

### Developer tooling kept from Bluefin-DX

# Command-line basics Bluefin shipped that base-main does not.
dnf5 install -y \
    git \
    gcc \
    gcc-c++ \
    make \
    zsh \
    fish \
    podman-compose \
    podman-tui

# Docker CE and VS Code, from their vendors' repos as Bluefin-DX does. Each
# repo stays disabled once installed, so only these packages come from it.
dnf5 config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sed -i 's/enabled=.*/enabled=0/g' /etc/yum.repos.d/docker-ce.repo
dnf5 install -y --enablerepo=docker-ce-stable \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin

tee /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=0
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
dnf5 install -y --enablerepo=code code

### Install Noctalia and its greetd greeter

# Noctalia itself comes from Fedora's own repos (packaged since Fedora 44).
dnf5 install -y noctalia

# Fedora does not package noctalia-greeter, so take the prebuilt git snapshot
# from the LionHeartP COPR. Enable the COPR only for this install: left on, its
# noctalia-git package could replace Fedora's noctalia on later updates.
dnf5 -y copr enable lionheartp/Hyprland
dnf5 install -y greetd noctalia-greeter-git
dnf5 -y copr disable lionheartp/Hyprland

# The COPR package drops the greeter's tmpfiles rule, which would create its
# state dir for a "greeter" user Fedora lacks. Our own rule, under
# system_files/usr/lib/tmpfiles.d/, creates it for "greetd" instead.

# Unlock the login keyring with the login password, so browsers and VS Code
# can read their stored secrets without a second prompt.
grep -q pam_gnome_keyring /etc/pam.d/greetd || {
    sed -i '/^auth.*substack.*system-auth/a -auth       optional     pam_gnome_keyring.so' /etc/pam.d/greetd
    sed -i '/^session.*include.*postlogin/a -session    optional     pam_gnome_keyring.so auto_start' /etc/pam.d/greetd
}
grep -q '^-auth.*pam_gnome_keyring' /etc/pam.d/greetd
grep -q '^-session.*pam_gnome_keyring' /etc/pam.d/greetd

### Brand the OS as MadeOfBlue

# bootc-image-builder names the installer ISO's boot menu entries after NAME
# in os-release ("Install Fedora Linux 44"), and ostree titles the installed
# system's boot entries with PRETTY_NAME. Rename both; leave ID, ID_LIKE and
# VERSION_ID alone so tooling that identifies the base distro keeps working.
# The image ships an empty /etc/hostname, so systemd falls back to
# DEFAULT_HOSTNAME; make that "madeofblue" instead of "fedora".
for f in /usr/lib/os-release /etc/os-release; do
    sed -i --follow-symlinks -E \
        -e 's/^NAME=.*/NAME="MadeOfBlue"/' \
        -e '/^PRETTY_NAME=/s/Fedora Linux/MadeOfBlue/' \
        -e 's/^DEFAULT_HOSTNAME=.*/DEFAULT_HOSTNAME="madeofblue"/' \
        "$f"
    grep -q '^NAME="MadeOfBlue"$' "$f"
    grep -q '^PRETTY_NAME=.*MadeOfBlue' "$f"
    grep -q '^DEFAULT_HOSTNAME="madeofblue"$' "$f"
done

### Enable services

# greetd running the Noctalia greeter is the login screen.
systemctl disable gdm.service || true
systemctl enable greetd.service

# Container engines. madeofblue-docker-group adds wheel members to the docker
# group on boot, as Bluefin-DX did.
systemctl enable docker.socket podman.socket

# Homebrew: unpack on first boot, then keep it updated.
systemctl enable brew-setup.service brew-update.timer brew-upgrade.timer

# Flathub only: drop Fedora's flatpak remote, which base-main would add on
# first boot. flatpak-preinstall.service (from system_files) then installs the
# apps listed under /usr/share/flatpak/preinstall.d/.
systemctl disable flatpak-add-fedora-repos.service || true

### Clean up

dnf5 clean all
