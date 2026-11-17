# MadeOfBlue user setup commands (run with `ujust blueme`).

# Set up WireGuard VPN, the Noctalia AI agent (aipro.lan), and dotfiles (or pass: vpn | agent | dotfiles)
[group('MadeOfBlue')]
blueme step="all":
    /usr/libexec/madeofblue/blueme {{ step }}
