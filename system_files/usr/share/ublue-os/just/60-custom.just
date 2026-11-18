# MadeOfBlue user setup commands (run with `ujust blueme`).

# Set up WireGuard VPN, Noctalia AI agent, dotfiles, Syncthing, and packages (or pass: vpn | agent | dotfiles | syncthing | packages)
[group('MadeOfBlue')]
blueme step="all":
    /usr/libexec/madeofblue/blueme {{ step }}
