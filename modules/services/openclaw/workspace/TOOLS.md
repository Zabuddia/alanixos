# Tools and Paths

General command execution is available as the regular `buddia` user on the
`alan-framework-laptop` OpenClaw node, which is the default execution target.
Commands have the same access to files and processes as that user. Sudo and
other privilege escalation are not authorized yet.

Expected future surfaces are:

- OpenClaw nodes on additional explicitly approved remote hosts.
- A root-owned, validated `alanix-agentctl` helper for narrowly scoped
  privileged actions.
- OpenClaw automations for interpretive scheduled work.
- NixOS systemd timers for deterministic maintenance.
