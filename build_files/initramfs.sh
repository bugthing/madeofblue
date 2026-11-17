#!/bin/bash

set -ouex pipefail

# Plymouth draws the boot splash from inside the initramfs, so files copied in
# from system_files/ (the MadeOfBlue boot logo at
# /usr/share/plymouth/themes/spinner/watermark.png) only show up at boot once
# the initramfs is rebuilt. Runs after the system_files COPY for that reason.
#
# bootc images ship a single kernel; build a generic (no-hostonly) initramfs
# for it, with the ostree module bootc needs to find the deployment.
#
# Only a directory holding a vmlinuz is a kernel: when Fedora's updates repo is
# a kernel ahead of the base image, packages installed by build.sh can leave an
# empty /usr/lib/modules/<newer version> behind.
KERNELS=(/usr/lib/modules/*/vmlinuz)
[ "${#KERNELS[@]}" -eq 1 ]
[ -f "${KERNELS[0]}" ]
KVER="$(basename "$(dirname "${KERNELS[0]}")")"

# /root is a symlink to /var/roothome, which only exists on a booted system;
# dracut fails to install it (while still exiting 0) unless it is present.
mkdir -p /var/roothome

dracut --no-hostonly --kver "$KVER" --reproducible --zstd --add ostree \
    --tmpdir /tmp -f "/usr/lib/modules/$KVER/initramfs.img"
chmod 0600 "/usr/lib/modules/$KVER/initramfs.img"
rmdir /var/roothome

# dracut can report errors yet exit 0, so fail the build unless the new
# initramfs really carries our logo.
lsinitrd -f usr/share/plymouth/themes/spinner/watermark.png \
    "/usr/lib/modules/$KVER/initramfs.img" \
    | cmp - /usr/share/plymouth/themes/spinner/watermark.png
