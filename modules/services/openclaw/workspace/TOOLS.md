# Tools and Paths

General command execution is available as the regular `buddia` user on
`alan-framework`, which is the default execution target. Reach other cluster
hosts through SSH and identify the remote target explicitly. Passwordless sudo
is available on the current cluster hosts. Sudo changes execution privilege,
not task authorization; follow `POLICY.md` before using it.

The control plane, model services, and default command execution all run on
`alan-framework`. Do not describe a remote SSH or explicitly selected node
target as the assistant's runtime location.

The native OpenClaw `cron` tool is available for one-shot and recurring agent
tasks. Prefer isolated sessions for background work. Define the exact schedule,
hosts, actions, and delivery behavior; scheduled work receives no additional
authorization beyond the job definition.

## Cluster rebuilds

Treat `nrs` as a request to run `nixos-rebuild switch` against the existing
repository state. It does not authorize changing `flake.lock`, updating inputs,
editing configuration, garbage collection, or cache cleanup.

For a multi-host rebuild:

1. Read the current hosts from `CLUSTER.md` and confirm reachability.
2. Rebuild remote hosts first through SSH, explicitly selecting each host:
   `cd /home/buddia/.nixos && sudo nixos-rebuild switch --flake path:/home/buddia/.nixos#HOST`.
   Do not rely on interactive shell aliases over SSH. Capture each exit status
   and final system path.
3. Rebuild `alan-framework` last by running
   `sudo systemctl start --no-block alanix-rebuild.service`. This system service
   survives an OpenClaw gateway restart. Before starting it, create a one-shot
   isolated cron follow-up that will check the service result, current system
   path, gateway health, and deliver the final report after reconnection.
4. Check the local result with
   `systemctl show alanix-rebuild.service -p ActiveState -p Result -p ExecMainStatus`
   and inspect failures with `journalctl -u alanix-rebuild.service`.

Never diagnose a Nix evaluation failure as stale cache or run garbage
collection without evidence and explicit authorization.

Use NixOS systemd timers for deterministic maintenance that does not require
agent reasoning.
