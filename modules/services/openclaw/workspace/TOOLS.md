# Tools and Paths

General command execution is available as the regular `buddia` user on
`alan-framework`, which is the default execution target. Reach other cluster
hosts through SSH and identify the remote target explicitly. Passwordless sudo
is available on `alan-framework` and, after SSH, on
`alan-framework-laptop`. Sudo changes execution privilege, not task
authorization; follow `POLICY.md` before using it.

The control plane, model services, and default command execution all run on
`alan-framework`. Do not describe a remote SSH or explicitly selected node
target as the assistant's runtime location.

The native OpenClaw `cron` tool is available for one-shot and recurring agent
tasks. Prefer isolated sessions for background work. Define the exact schedule,
hosts, actions, and delivery behavior; scheduled work receives no additional
authorization beyond the job definition.

Expected future surfaces are:

- OpenClaw nodes on additional explicitly approved remote hosts.
- NixOS systemd timers for deterministic maintenance.
