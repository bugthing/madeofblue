# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Homebrew, packaged by Universal Blue the same way Bluefin ships it: a tarball
# that brew-setup.service unpacks into /home/linuxbrew on first boot, plus its
# update timers and shell profile.
FROM ghcr.io/ublue-os/brew:latest AS brew

# Base Image: Universal Blue's desktop-less Fedora Atomic image (codecs, drivers,
# Flathub, podman, distrobox) without Bluefin's GNOME desktop. build.sh adds
# Niri, Noctalia and the developer tooling we kept from Bluefin-DX.
FROM ghcr.io/ublue-os/base-main:44

COPY --from=brew /system_files /

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### SYSTEM OVERLAY
## Files under system_files/ are copied verbatim onto the final image, preserving their
## path relative to /. This is where default user skel configs, session files, etc live.

COPY system_files /

## Units shipped in system_files: flatpak-preinstall.service installs the apps
## under /usr/share/flatpak/preinstall.d/; madeofblue-docker-group.service adds
## wheel users to the docker group.
RUN systemctl enable flatpak-preinstall.service madeofblue-docker-group.service

### AGENT PLUGIN
## Fail the build if the agent plugin did not land where agent.toml expects it.
RUN test -f /usr/share/madeofblue/noctalia-plugins/agent/plugin.toml

### DEFAULT SESSION CONFIG
## Fail the build on a Niri config error, or a screensaver that cannot start.
RUN niri validate -c /etc/skel/.config/niri/config.kdl && \
    python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" /usr/libexec/madeofblue/screensaver.py && \
    command -v madeofblue-screensaver foot

## Rebuild the initramfs so the boot splash (Plymouth) picks up the MadeOfBlue
## logo from system_files.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/initramfs.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
