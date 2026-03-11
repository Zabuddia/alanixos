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
- Service leadership is coordinated through `etcd` instead of timer-driven ping checks.
- A node stays standby while a fresh remote leader record exists for that service.
- Higher-priority nodes wait less time before campaigning, so they win initial placement, but they do not automatically reclaim a service after they return.
- Standby nodes sync from the currently published leader over SSH.
- The active node relinquishes leadership if its local `etcd` endpoint stops committing health checks or the managed service stops passing local unit checks.

Control-plane groundwork:
- `alanix.cluster.controlPlane.etcd` is the intended shared consensus layer for 3+ identical nodes.
- It is meant to run only over the private cluster transport and only with an odd number of members.
- It is now enabled for the three declared nodes: `alan-big-nixos`, `randy-big-nixos`, and `alan-node-nixos`.
- On first bootstrap, rebuild all three nodes onto the same config. `etcd` now waits indefinitely for quorum instead of being killed by the default systemd startup timeout.
- Verify the local endpoint first with `alanix-etcd-local-health`, then cluster quorum with `alanix-etcd-health`, and inspect members with `alanix-etcd-members`.
- If the transport addresses change after `etcd` has already been bootstrapped, the existing `/var/lib/etcd` state must be replaced or the member URLs must be updated explicitly. At the current stage, a wipe/rebootstrap is acceptable because `etcd` is not yet carrying application state.
- `alanix-failover-status` prints the currently published leader metadata for each failover-managed service.

Cluster transport notes:
- The repo currently uses Tailscale as the private inter-node transport.
- `alanix.cluster.transport.interface` controls which interface cluster-only ports open on.
- `alanix.cluster.nodes.<name>.clusterAddress` is the address etcd, failover checks, backups, and private service access use.
- `alanix.cluster.nodes.<name>.clusterDnsName` is the preferred private DNS name for inter-node SSH/control traffic.
