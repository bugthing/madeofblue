#!/bin/bash

set -ouex pipefail

### Install packages

# Wayland compositor (Niri) and the Wayland/GPU stack it needs.
dnf5 install -y \
    niri \
    gdm \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-gnome \
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
    fuzzel \
    NetworkManager-tui \
    pipewire \
    wireplumber \
    polkit \
    lxpolkit

# Build tooling required to compile Noctalia from source.
dnf5 install -y \
    git \
    gcc \
    gcc-c++ \
    clang \
    cmake \
    meson \
    ninja-build \
    just \
    cargo \
    rust \
    pkgconf-pkg-config

# Noctalia build dependencies (see BUILDING.md in noctalia-dev/noctalia).
dnf5 install -y \
    wayland-devel \
    wayland-protocols-devel \
    libEGL-devel \
    mesa-libGLES-devel \
    freetype-devel \
    fontconfig-devel \
    cairo-devel \
    pango-devel \
    harfbuzz-devel \
    libxkbcommon-devel \
    glib2-devel \
    libsecret-devel \
    libsodium-devel \
    sdbus-cpp-devel \
    pipewire-devel \
    wireplumber-devel \
    pam-devel \
    polkit-devel \
    libcurl-devel \
    libwebp-devel \
    libjxl-devel \
    libsndfile-devel \
    librsvg2-devel \
    libqalculate-devel \
    libxml2-devel \
    md4c-devel \
    tomlplusplus-devel \
    libical-devel \
    json-devel \
    stb_image_resize2-devel \
    stb_image_write-devel \
    jemalloc-devel

### Build and install Noctalia

NOCTALIA_SRC="/tmp/noctalia-src"
git clone --depth=1 https://github.com/noctalia-dev/noctalia.git "${NOCTALIA_SRC}"
pushd "${NOCTALIA_SRC}"
just configure release /usr
just build release
just install release
popd
rm -rf "${NOCTALIA_SRC}"

### Enable services

# GDM gives us a Wayland-capable login greeter that can launch the Niri session.
systemctl enable gdm.service
systemctl enable NetworkManager.service
systemctl enable polkit.service

### Clean up

dnf5 clean all
