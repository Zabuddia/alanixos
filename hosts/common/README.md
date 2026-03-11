# `hosts/common` Layout

- `core/`
  - Cluster-wide shared configuration and host basics (`cluster`, `wireguard`, `dynamic-dns`, `secrets`, `users`).
- `services/`
  - Service wrappers that map `alanix.cluster.services.*` into `alanix.*` module settings.
- `services/failover/`
  - Per-service failover controller instance wiring.
- `services/backups/`
  - Per-service restic backup instance wiring.
- `service-helpers/`
  - Reusable helper constructors for failover/backup instance definitions.

When adding a new clustered service:
1. Add service options to `modules/cluster.nix`.
2. Add service module wrapper in `hosts/common/services/`.
3. Add failover and backup wrappers in `hosts/common/services/{failover,backups}/`.
4. Import those wrappers in host defaults (`hosts/*/default.nix`).
5. Add concrete service settings in `hosts/common/core/cluster.nix`.

Current failover policy:
- Automatic failover, manual failback.
- A node stays standby while any remote node is already active.
- Higher-priority nodes do not automatically reclaim a service after they return.
- Promotion is blocked if a lower-priority active node is still detected or if pre-promotion sync fails.

Control-plane groundwork:
- `alanix.cluster.controlPlane.etcd` is the intended shared consensus layer for 3+ identical nodes.
- It is meant to run only over WireGuard and only with an odd number of members.
- It is now enabled for the three declared nodes: `alan-big-nixos`, `randy-big-nixos`, and `alan-node-nixos`.
- First bootstrap should be rolled out to all three nodes close together while `initialClusterState = "new"`.
- Verify quorum on any node with `alanix-etcd-health` and inspect members with `alanix-etcd-members`.

WireGuard topology notes:
- `wireguardListenPort` is the node's local UDP listen port.
- `wireguardPublicEndpointPort` is the externally advertised UDP port and can differ when NAT/port-forwarding rewrites ports.
- For nodes in the same site/NAT, set `site` and `wireguardLanEndpointHost` so they use a LAN/private endpoint instead of hairpinning through the public address.
- If `.local` discovery is unreliable, prefer a stable private overlay endpoint such as a Tailscale IP or MagicDNS name for `wireguardLanEndpointHost`.
