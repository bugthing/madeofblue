#!/bin/bash

set -ouex pipefail

### Install packages

# Wayland compositor (Niri) and the Wayland/GPU stack it needs.
# GDM, polkit, PipeWire/WirePlumber and NetworkManager already ship with
# bluefin-dx (inherited from silverblue-main); we only add what Niri needs
# on top.
dnf5 install -y \
    niri \
    xdg-desktop-portal-gtk \
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
    lxpolkit

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

### Brand the OS as MadeOfBlue

# bootc-image-builder names the installer ISO's boot menu entries after NAME
# in os-release ("Install Bluefin 44"), and ostree titles the installed
# system's boot entries with PRETTY_NAME. Rename both; leave ID, ID_LIKE and
# VERSION_ID alone so tooling that identifies the base distro keeps working.
for f in /usr/lib/os-release /etc/os-release; do
    sed -i --follow-symlinks -E \
        -e 's/^NAME=.*/NAME="MadeOfBlue"/' \
        -e '/^PRETTY_NAME=/s/Bluefin/MadeOfBlue/' \
        "$f"
    grep -q '^NAME="MadeOfBlue"$' "$f"
    grep -q '^PRETTY_NAME=.*MadeOfBlue' "$f"
done

### Enable services

# Replace bluefin-dx's default GDM with greetd running the Noctalia greeter,
# which lets the user pick between the GNOME session and Niri at login.
systemctl disable gdm.service || true
systemctl enable greetd.service

### Clean up

dnf5 clean all
