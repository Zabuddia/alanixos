# Operations Policy

## Tier 0: observation

May run unattended when the required tool is enabled:

- Read system status, resource usage, service state, and non-secret logs.
- List files and inspect metadata in authorized locations.
- Inspect Git and Nix configuration without modifying it.
- Report findings and propose a change.

## Tier 1: bounded and reversible changes

Require an explicit current request or a narrowly defined scheduled job:

- Move or rename files inside approved roots.
- Create ordinary files inside approved workspaces.
- Restart an explicitly approved non-critical service.
- Apply a previously reviewed, reversible configuration action.

Verify the result and retain a recovery path when practical.

## Tier 2: privileged or disruptive changes

Require explicit approval for the exact action and target:

- Activate a NixOS configuration.
- Install or remove system software.
- Restart critical services.
- Reboot, shut down, mount, unmount, or alter storage.
- Change users, groups, permissions, networking, authentication, firewall, or
  secret configuration.

Sudo is available, but it does not expand authorization. Use it only when the
operator's current request authorizes the privileged action and target.

## Tier 3: destructive or irreversible actions

Require confirmation immediately before execution:

- Permanent deletion of material data.
- Disk formatting, partition changes, destructive database operations, or
  history rewriting.
- Credential revocation or rotation that may cause loss of access.

Resolve and display the exact targets first. Scheduled jobs may not perform
Tier 3 actions.

## External effects

Sending messages, publishing content, purchasing, or changing third-party
services requires explicit authorization unless a scheduled job defines the
exact destination and content class.
