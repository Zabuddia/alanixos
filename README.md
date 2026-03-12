# Alanixos Phase A

Phase A is a flake-based, inventory-driven NixOS homelab cluster for whole-site active/passive hosting. One node is declaratively active, standby nodes are fully configured but keep mutable public services stopped, and promotion is done by changing `cluster/default.nix` and rebuilding.

## Repo Layout

The main control plane is [`cluster/default.nix`](/home/buddia/alanixos/cluster/default.nix). It defines:

- cluster-wide settings such as `domain`, `activeNode`, WireGuard, Cloudflare, and backup defaults
- node inventory under `nodes.<hostname>`
- service inventory under `services.<name>`

Host files stay thin:

- [`hosts/alan-big-nixos/default.nix`](/home/buddia/alanixos/hosts/alan-big-nixos/default.nix)
- [`hosts/randy-big-nixos/default.nix`](/home/buddia/alanixos/hosts/randy-big-nixos/default.nix)

Each host imports:

- its `hardware-configuration.nix`
- the shared cluster profile at [`modules/cluster/default.nix`](/home/buddia/alanixos/modules/cluster/default.nix)
- [`modules/tailscale.nix`](/home/buddia/alanixos/modules/tailscale.nix) as fallback-only access

Only `alan-big-nixos` also imports [`modules/bitcoin.nix`](/home/buddia/alanixos/modules/bitcoin.nix). Bitcoin is intentionally isolated from the active/passive app stack.

## How It Works

### Active and standby

- `cluster.cluster.activeNode` is the single source of truth for role selection.
- The active node runs the mutable app services, WAN-facing Caddy routes, WireGuard service listeners, Tor onion services, and outgoing backup timers.
- Standby nodes still evaluate the same services, users, secrets, restore helpers, and backup receive directories, but they do not start the mutable app units.

### Networking

- WireGuard full mesh is generated from inventory and uses `wg0`.
- Tailscale is still imported on every host, but the cluster logic does not depend on it.
- Caddy routes are generated centrally from inventory. WAN and WireGuard access are live only on the active node.
- Tor onion services are generated centrally from inventory and use sops-backed hidden-service keys. The secret material lives in `secrets.yaml` as base64-encoded `hs_ed25519_secret_key` data and is decoded into `/run/alanix/tor-secrets/<service>/hs_ed25519_secret_key` before Tor starts.

### Backups and restore

- Restic runs with systemd timers.
- The active node pushes per-service backups over WireGuard SSH to every standby node.
- Receivers use a dedicated `cluster-backup` account with forced SFTP.
- Restore helpers are installed as:
  - `alanix-restore-filebrowser`
  - `alanix-restore-forgejo`
  - `alanix-restore-immich`
  - `alanix-restore-invidious`
- Restore helpers use local incoming repositories on the standby and then run any service-specific restore hook, such as PostgreSQL import for Immich and Invidious.

### Cloudflare

- Phase A does not automate failover.
- [`modules/cluster/cloudflare.nix`](/home/buddia/alanixos/modules/cluster/cloudflare.nix) renders `/etc/alanix/cloudflare-records.json` and installs `alanix-cloudflare-sync-active`.
- Later automation should hook into that module instead of scattering DNS logic through app modules.

## Declarative vs bootstrap-only

Declarative today:

- system users and groups
- SSH, firewall, WireGuard mesh, Caddy, Tor, restic plumbing
- Filebrowser users
- Forgejo users/admin
- Immich admin bootstrap and user reconciliation through the API
- Invidious local user bootstrap/reconcile
- app state paths, ports, domains, backup policy, and restore hooks

Bootstrap-only or upstream-limited:

- some app-internal objects still require first service startup before reconciliation can run
- some app-internal bootstrap flows still depend on upstream APIs rather than pure config files

## Add a Node

1. Add the node under `nodes` in [`cluster/default.nix`](/home/buddia/alanixos/cluster/default.nix).
2. Add `hosts/<hostname>/default.nix`.
3. Add `hosts/<hostname>/hardware-configuration.nix`.
4. Add the runtime age key to [`secrets/keys.nix`](/home/buddia/alanixos/secrets/keys.nix).
5. Add the host's `wireguard-private-keys/<hostname>` secret to `secrets/secrets.yaml`.
6. Regenerate `.sops.yaml` and rekey secrets if needed:

```bash
./scripts/generate-sops-config.sh
./scripts/update-sops-keys.sh
```

No shared service module edits are required for a new node.

## Add a Service

1. Add the service definition to `services` in [`cluster/default.nix`](/home/buddia/alanixos/cluster/default.nix).
2. Add or extend the corresponding app module if the service is new.
3. Extend [`modules/cluster/services.nix`](/home/buddia/alanixos/modules/cluster/services.nix) so inventory fields map into the app module.
4. If the service needs custom backup preparation or restore logic, add that in the service's `backup` section in inventory.

## Promote a Standby

Phase A promotion is manual and declarative:

1. Change `cluster.cluster.activeNode` in [`cluster/default.nix`](/home/buddia/alanixos/cluster/default.nix).
2. Rebuild the node you are promoting:

```bash
sudo nixos-rebuild switch --flake .#randy-big-nixos
```

3. Restore the needed service data from the local incoming repositories on that node if required.
4. Run `alanix-cloudflare-sync-active` on the newly active node to point Cloudflare DNS at its current public IP.

## Safe Testing

Basic evaluation:

```bash
nix flake show
nix build .#nixosConfigurations.alan-big-nixos.config.system.build.toplevel
nix build .#nixosConfigurations.randy-big-nixos.config.system.build.toplevel
```

Operational checks:

```bash
alanix-cluster-role
alanix-cluster-services
./scripts/show-service-addresses.sh
```

Promotion dry run:

1. Change `activeNode`.
2. Build both affected hosts.
3. Confirm the old active no longer has Caddy/Tor/app units wanted.
4. Confirm the new active has the reverse.

## Secrets Notes

Base secrets are declared centrally:

- `password-hashes/buddia`
- `cloudflare/api-token`
- `restic/cluster-password`
- `cluster/sync-private-key`
- `wireguard-private-keys/<hostname>`
- `tor/<service>/secret-key-base64`

App modules declare the app-specific secrets they consume. Existing `service-passwords/*` secrets are reused for Phase A bootstrap.

## Managing Tor Secrets

Each Tor-enabled service now expects a sops secret at:

- `tor/filebrowser/secret-key-base64`
- `tor/forgejo/secret-key-base64`
- `tor/immich/secret-key-base64`
- `tor/invidious/secret-key-base64`

The value is the base64 encoding of the service's `hs_ed25519_secret_key` file, not the hostname and not the whole hidden-service directory.

One clean way to generate a new key is:

```bash
tmpdir="$(mktemp -d)"
cat >"$tmpdir/torrc" <<EOF
DataDirectory $tmpdir/data
SocksPort 0
HiddenServiceDir $tmpdir/hidden
HiddenServicePort 80 127.0.0.1:1
EOF
timeout 10s tor -f "$tmpdir/torrc" >/dev/null 2>&1 || true
cat "$tmpdir/hidden/hostname"
base64 -w0 "$tmpdir/hidden/hs_ed25519_secret_key"
rm -rf "$tmpdir"
```

Then edit `secrets/secrets.yaml` with `sops` and set the matching key:

```bash
sops secrets/secrets.yaml
```

Example entry:

```yaml
tor:
  filebrowser:
    secret-key-base64: <BASE64_VALUE>
```

Repeat for each Tor-enabled service, then rebuild the active node. Because the onion hostname is derived from the secret key, promotion no longer depends on restoring `/var/lib/tor/onion`.
