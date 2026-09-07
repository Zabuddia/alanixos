# Cluster Inventory

Control plane:

- `alan-framework`: OpenClaw gateway, LiteLLM, and local model services.
- Nix configuration repository: `/home/buddia/.nixos`
- Private cluster transport: Tailscale/Headscale.

Known NixOS hosts:

- `alan-framework`
- `alan-framework-laptop`
- `alan-node`
- `alan-optiplex`
- `alan-tv`
- `alan-big-nixos`
- `randy-big-nixos`
- `fife-tv`

Hostnames are inventory identifiers, not proof that a host is online or that
an operation is authorized. Use a bounded service-specific status command when
one exists; for desktop hosts, use `desktop-inspect HOST status`, never raw SSH
or a similarly named Home Assistant entity. This file is the authoritative host
inventory; do not substitute lists from secrets or unrelated configuration.
