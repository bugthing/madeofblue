#!/bin/bash

set -ouex pipefail

# Bluefin-DX wires ccache in front of gcc/clang by default. Under buildah's
# cache-mount overlay for /var/cache it hits a hardlink race ("ccache: error:
# File exists") during Noctalia's parallel ninja build, so disable it for our
# from-source compiles rather than fight the overlay semantics.
export CCACHE_DISABLE=1

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
    fuzzel \
    lxpolkit

# Build tooling required to compile Noctalia and noctalia-greeter from source.
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

# noctalia-greeter build dependencies on top of the above (see its README.md).
dnf5 install -y \
    greetd \
    dbus \
    wlroots-devel

### Build and install Noctalia

NOCTALIA_SRC="/tmp/noctalia-src"
git clone --depth=1 https://github.com/noctalia-dev/noctalia.git "${NOCTALIA_SRC}"
pushd "${NOCTALIA_SRC}"
just configure release /usr
just build release
just install release
popd
rm -rf "${NOCTALIA_SRC}"

### Build and install the Noctalia greetd greeter

# The upstream Justfile's configure-release target has no prefix knob, so we
# drive meson directly to install under /usr instead of its default /usr/local.
# We also skip scripts/setup_greeter_system.sh: Fedora's greetd RPM already
# provides the system user, PAM stack and unit that script exists to create on
# distros without one; system_files/etc/greetd/config.toml does the wiring.
NOCTALIA_GREETER_SRC="/tmp/noctalia-greeter-src"
git clone --depth=1 https://github.com/noctalia-dev/noctalia-greeter.git "${NOCTALIA_GREETER_SRC}"
pushd "${NOCTALIA_GREETER_SRC}"
meson setup build-release --buildtype=release --prefix=/usr
meson compile -C build-release
meson install -C build-release
popd
rm -rf "${NOCTALIA_GREETER_SRC}"

### Enable services

# Replace bluefin-dx's default GDM with greetd running the Noctalia greeter,
# which lets the user pick between the GNOME session and Niri at login.
systemctl disable gdm.service || true
systemctl enable greetd.service

### Clean up

dnf5 clean all
