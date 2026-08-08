# Tools and Paths

General command execution is available as the regular `buddia` user on the
`alan-framework-laptop` OpenClaw node, which is the default execution target.
Commands have the same access to files and processes as that user. Passwordless
sudo is available on `alan-framework-laptop` and, after SSH, on
`alan-framework`. Sudo changes execution privilege, not task authorization;
follow `POLICY.md` before using it.

Expected future surfaces are:

- OpenClaw nodes on additional explicitly approved remote hosts.
- OpenClaw automations for interpretive scheduled work.
- NixOS systemd timers for deterministic maintenance.
