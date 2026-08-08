# Tools and Paths

No shell execution or privileged tools are authorized yet.

The `alan-node` OpenClaw node is connected only as a transport endpoint. Enable
individual execution capabilities later, after their approval boundary has
been designed and tested. An unavailable tool is a hard boundary; report it
instead of substituting a broader mechanism.

Expected future surfaces are:

- OpenClaw node execution for explicitly approved remote hosts.
- Read-only local diagnostics.
- A root-owned, validated `alanix-agentctl` helper for narrowly scoped
  privileged actions.
- OpenClaw automations for interpretive scheduled work.
- NixOS systemd timers for deterministic maintenance.
