# MadeOfBlue user setup and update commands (run with `ujust`).

# Set up WireGuard VPN, Noctalia AI agent, dotfiles, Syncthing, and packages (or pass: vpn | agent | dotfiles | syncthing | packages)
[group('MadeOfBlue')]
blueme step="all":
    /usr/libexec/madeofblue/blueme {{ step }}

# Update system image, Flatpaks, Distrobox containers, and Homebrew packages
[group('System')]
update:
    #!/usr/bin/bash
    set -euo pipefail
    if systemctl is-enabled ublue-update.timer 2>/dev/null | grep -q enabled; then
        echo "Starting the ublue-update service"
        sudo systemctl start ublue-update.service
    else
        if command -v rpm-ostree >/dev/null 2>&1; then
            rpm-ostree update
        else
            sudo bootc upgrade
        fi
        if flatpak remotes | grep -q system; then
            flatpak update -y
        fi
        if flatpak remotes | grep -q user; then
            flatpak update --user -y
        fi
        if command -v distrobox >/dev/null 2>&1; then
            distrobox upgrade -a
        fi
    fi
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        /home/linuxbrew/.linuxbrew/bin/brew update
        /home/linuxbrew/.linuxbrew/bin/brew upgrade
    elif command -v brew >/dev/null 2>&1; then
        brew update
        brew upgrade
    fi
