# `hosts/common` Layout

- `core/`
  - Cluster-wide shared configuration and host basics (`cluster`, `secrets`, `users`).
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
- It is meant to run only over the private cluster transport and only with an odd number of members.
- It is now enabled for the three declared nodes: `alan-big-nixos`, `randy-big-nixos`, and `alan-node-nixos`.
- First bootstrap should be rolled out to all three nodes close together while `initialClusterState = "new"`.
- Verify quorum on any node with `alanix-etcd-health` and inspect members with `alanix-etcd-members`.

Cluster transport notes:
- The repo currently uses Tailscale as the private inter-node transport.
- `alanix.cluster.transport.interface` controls which interface cluster-only ports open on.
- `alanix.cluster.nodes.<name>.clusterAddress` is the address etcd, failover checks, backups, and private service access use.
- `alanix.cluster.nodes.<name>.clusterDnsName` is the preferred private DNS name for inter-node SSH/control traffic.
