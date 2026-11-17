# madeofblue

A [bootc](https://github.com/bootc-dev/bootc) desktop image built on Universal Blue's desktop-less [`base-main`](https://github.com/ublue-os/main) (`ghcr.io/ublue-os/base-main:44`), with the [Niri](https://github.com/YaLTeR/niri) scrollable-tiling Wayland compositor and the [Noctalia](https://github.com/noctalia-dev/noctalia) desktop shell (bar, launcher, notifications, control center, wallpaper, and lock screen) as its only desktop, plus the developer tooling we used from [Bluefin-DX](https://github.com/ublue-os/bluefin): Homebrew, Docker, Podman and VS Code.

This repo is derived from [ublue-os/image-template](https://github.com/ublue-os/image-template).

## What's in the image

- **Base:** Universal Blue's `base-main`: Fedora Atomic with codecs, drivers, Flathub, Podman and distrobox, and no GNOME. Earlier versions of this image were built on Bluefin-DX, which carries a full GNOME desktop we did not use; dropping it shrinks the image from about 14 GB to about 9 GB.
- **Kept from Bluefin-DX:** Homebrew (copied from `ghcr.io/ublue-os/brew`; `brew-setup.service` unpacks it into `/home/linuxbrew` on first boot and timers keep it updated), Docker CE with buildx and compose (wheel users join the `docker` group on boot), `podman-compose`, `podman-tui`, VS Code, git, gcc/make, zsh, fish, htop, and Bazaar from Flathub.
- **Desktop pieces GNOME used to provide:** Nautilus (`Mod+Shift+F`), GNOME Keyring (unlocked at login through greetd's PAM stack), the GNOME and GTK portals, `tuned-ppd` power profiles, and Noto/JetBrains Mono fonts.
- **Compositor:** Niri (installed via `dnf5`), plus `swaybg`/`swayidle`/`swaylock` as fallbacks and `foot` (terminal). Noctalia provides the app launcher (`Mod+Space`).
- **Desktop shell:** [Noctalia](https://github.com/noctalia-dev/noctalia), installed from Fedora's own `noctalia` package (binary at `/usr/bin/noctalia`, assets under `/usr/share/noctalia/`).
- **Login screen:** [`greetd`](https://sr.ht/~kennylevinsen/greetd/) running [Noctalia's own greeter](https://github.com/noctalia-dev/noctalia-greeter) (the prebuilt `noctalia-greeter-git` snapshot from the [LionHeartP COPR](https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland/), since Fedora does not package it), configured via `system_files/etc/greetd/config.toml`. The greeter's session picker reads the standard `/usr/share/wayland-sessions/*.desktop` entries; Niri is the only session.
- **Default session config:** `system_files/etc/skel/.config/niri/config.kdl` is seeded into every new user's home directory. It launches Noctalia via `spawn-at-startup`, and ships a keybinding set built around Noctalia (`Mod+Space` launcher, `Mod+Escape` session menu, `Mod+Return` terminal, `Mod+W` close, `Mod+F` fullscreen, `Mod+T` float, `Mod+O` overview, `Mod+1..9` workspaces, `Mod+Shift+L` lock). `Mod+K` lists every binding on screen.
- **Screensaver and lock:** after 2 minutes idle, Noctalia starts `madeofblue-screensaver`, a retro pixel-art skater rolling through a night city in a fullscreen `foot` window; any input closes it. After 5 minutes idle the session locks. Both timers live in `/etc/skel/.config/noctalia/idle.toml` and pause while "keep awake" (`Mod+Ctrl+I`) is on or a video is playing. `madeofblue-screensaver preview` runs it in the current terminal. Like the Niri config, `idle.toml` reaches new users only; existing users can copy it into `~/.config/noctalia/`.
- **Browsers:** Firefox and Google Chrome are installed from Flathub on first boot. Both are listed in `/usr/share/flatpak/preinstall.d/madeofblue-browsers.preinstall`, which `flatpak-preinstall.service` reads; Bazaar is installed the same way. A browser a user uninstalls stays uninstalled.
- **Agent:** a Noctalia plugin (`/usr/share/madeofblue/noctalia-plugins/agent/`) adds a robot icon to the bar (`Mod+A` also opens it). The first click asks for an LLM provider (OpenAI-compatible, including local Ollama, or Anthropic), host, model and token; settings are saved to Noctalia's private plugin data directory, readable only by you. Afterwards the icon opens a chat in which the agent proposes commands and file edits; nothing runs until you click **Run**. Output is scrubbed for known secret formats, and output from sensitive paths or containing secrets is held for your review before it is sent. Redaction is best effort; use a local model for anything you must not share. The plugin is wired in through `/etc/skel/.config/noctalia/agent.toml`, so it reaches new users only; existing users can copy that file into `~/.config/noctalia/`. Because Noctalia replaces (not merges) arrays, a user `config.toml` that sets `[plugins] enabled`, `[[plugins.source]]` or `[bar.default] end` must repeat the agent's entries. Unit tests: `just test-agent`.

## Building locally

You need `podman` (or `docker`) installed. From the repository root:

```bash
just build madeofblue latest
# or, without Just:
podman build -t madeofblue:latest .
```

The build installs Noctalia and its greeter as prebuilt RPMs, so nothing is compiled, but it pulls the base image (about 6 GB) and needs network access for `dnf5`.

To boot the image locally in a VM without installing it anywhere, see the [Justfile Documentation](#justfile-documentation) section below (`just build-qcow2`, `just run-vm-qcow2`, etc.).

## Rebasing an existing Fedora Atomic system onto this image

From any `bootc`-based system (Fedora Silverblue/Kinoite, or any Universal Blue image):

```bash
# One-time, only needed the first time you rebase to an unsigned/differently-signed image:
sudo bootc switch --enforce-container-sigpolicy=false ghcr.io/bugthing/madeofblue:latest

# Normal rebase once the image is signed and you trust it:
sudo bootc switch ghcr.io/bugthing/madeofblue:latest
```

Reboot to apply:

```bash
sudo systemctl reboot
```

After rebooting, select the "Niri" session at the Noctalia greeter login screen. To switch back to your previous image at any point, run `sudo bootc rollback` and reboot again.

## Building or flashing an installer ISO

The [`build-disk.yml`](./.github/workflows/build-disk.yml) GitHub Actions workflow uses [bootc-image-builder](https://osbuild.org/docs/bootc/) to turn the published container image into an installer ISO and QCOW2 disk image after every image build on `main`.

To download the latest CI-built ISO and flash it to a USB drive:

```bash
just flash-iso
```

To build an ISO locally instead:

```bash
just build-iso madeofblue latest
```

or invoke `bootc-image-builder` directly:

```bash
sudo podman run --rm -it --privileged \
  --pull=newer \
  -v ./disk_config/iso.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type iso \
  --config /config.toml \
  ghcr.io/bugthing/madeofblue:latest
```

The resulting ISO under `./output/bootiso/` will boot into an offline installer for this image.

## Verifying changes

Run the agent plugin unit tests:

```bash
just test-agent
```

Lint the `Containerfile`:

```bash
podman run --rm -i docker.io/hadolint/hadolint < Containerfile
```

and shellcheck the scripts:

```bash
just lint
```

## Justfile Documentation

The [`Justfile`](./Justfile) contains recipes for building and testing the container image, virtual machine images, and the Noctalia agent plugin.

### Environment Variables

- `image_name`: The name of the image (default: `"madeofblue"`).
- `default_tag`: The default tag for the image (default: `"latest"`).
- `bib_image`: The Bootc Image Builder (BIB) image (default: `"quay.io/centos-bootc/bootc-image-builder:latest"`).

### Building the Image

- `just build [target_image] [tag]`: Builds the container image using Podman.

### Building and Running Virtual Machines and ISOs

Available image types are `qcow2`, `iso`, and `raw`:

- `just build-qcow2 [target_image] [tag]` (alias `just build-vm`): Builds a QCOW2 virtual machine image from an existing container image.
- `just rebuild-qcow2 [target_image] [tag]` (alias `just rebuild-vm`): Rebuilds the container image and then builds a QCOW2 image.
- `just run-vm-qcow2 [target_image] [tag]` (alias `just run-vm`): Runs a virtual machine from the QCOW2 image in QEMU via Podman.
- `just spawn-vm [rebuild="0"] [type="qcow2"] [ram="6G"]`: Runs a virtual machine using `systemd-vmspawn`.
- `just flash-iso`: Downloads the newest CI-built installer ISO via `gh` and writes it to a selected USB drive.

### Testing and Maintenance

- `just test-agent`: Runs the Noctalia agent plugin's Luau unit test suite (`tests/agent/run.luau`).
- `just check` / `just fix`: Checks or formats the `Justfile` syntax.
- `just lint` / `just format`: Runs `shellcheck` or `shfmt` on all Bash scripts.
- `just clean`: Removes local build artifacts (`_build*`, `output/`, etc.).
