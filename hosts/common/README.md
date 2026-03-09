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
