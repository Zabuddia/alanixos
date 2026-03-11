# Fresh NixOS + Flake + sops-nix Bootstrap Runbook

This is a command-by-command runbook for bringing up a new machine from this
repo.

There are two machine types:
- Runtime host: decrypts at boot using `/var/lib/sops-nix/key.txt`
- Editor laptop: edits and rekeys secrets using `~/.config/sops/age/keys.txt`

Keep those keys separate. Do not copy a server key into a user `sops` profile
unless that machine is intentionally also acting as an editor.

## Common Variables

Set these on whichever machine you are working on:

```bash
export REPO="$HOME/.nixos"
export GIT_REPO="git@github.com:Zabuddia/alanixos.git"
```

For a new runtime host, also set:

```bash
export HOST="randy-big-nixos"
```

For a new editor laptop, also set:

```bash
export EDITOR_NAME="alan-laptop"
```

## Runbook A: New Runtime Host

### 1. Fresh install

Do this in the NixOS installer/UI:
1. Install NixOS
2. Create user `buddia`
3. Boot the installed system
4. Connect to the internet

### 2. Install temporary tools on the new host

Run on the new host:

```bash
nix-shell -p git sops age
```

### 3. Create SSH key for GitHub

Run on the new host:

```bash
ssh-keygen -t ed25519 -C "fife.alan@protonmail.com"
cat ~/.ssh/id_ed25519.pub
```

Add the printed key to GitHub -> Settings -> SSH keys.

### 4. Clone the repo

Run on the new host:

```bash
git clone "$GIT_REPO" "$REPO"
cd "$REPO"
```

### 5. Create the host runtime key

Run on the new host:

```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 0400 /var/lib/sops-nix/key.txt
sudo chown root:root /var/lib/sops-nix/key.txt
sudo age-keygen -y /var/lib/sops-nix/key.txt
```

Copy the printed `age1...` public key.

### 6. Add the host key to the repo inventory

Run on an existing machine that can already decrypt secrets:

```bash
cd "$REPO"
nano secrets/keys.nix
```

Add the new public key under `hosts` and make sure the correct
`creationRules` entry includes `"$HOST"`.

Example shape:

```nix
hosts = {
  randy-big-nixos = {
    recipient = "age1...";
    description = "Root-only runtime key stored at /var/lib/sops-nix/key.txt.";
  };
};

creationRules = [
  {
    pathRegex = "^secrets/.*\\.ya?ml$";
    editors = [ "alan-laptop" ];
    hosts = [ "randy-big-nixos" "alan-big-nixos" ];
  }
];
```

### 7. Regenerate `.sops.yaml` and rekey the secrets

Run on an existing machine that can already decrypt secrets:

```bash
cd "$REPO"
./scripts/generate-sops-config.sh
./scripts/update-sops-keys.sh
git add secrets/keys.nix .sops.yaml secrets/secrets.yaml
git commit -m "Add $HOST sops recipient"
git push
```

If you do not yet have an editor laptop key, you can temporarily run the rekey
step on an existing server that already has a working host key:

```bash
cd "$REPO"
sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt ./scripts/update-sops-keys.sh
```

### 8. Pull the updated repo onto the new host

Run on the new host:

```bash
cd "$REPO"
git pull
```

### 9. Copy the hardware config into the repo

Run on the new host:

```bash
cp /etc/nixos/hardware-configuration.nix "$REPO/hosts/$HOST/hardware-configuration.nix"
```

### 10. Rebuild

Run on the new host:

```bash
sudo nixos-rebuild switch --flake "$REPO#$HOST"
```

### 11. Reboot

Run on the new host:

```bash
reboot
```

## Runbook B: New Editor Laptop

### 1. Fresh install

Do this in the NixOS installer/UI:
1. Install NixOS
2. Create user `buddia`
3. Enable networking
4. Boot the installed system

### 2. Install temporary tools on the laptop

Run on the new laptop:

```bash
nix-shell -p git sops age
```

### 3. Create SSH key for GitHub

Run on the new laptop:

```bash
ssh-keygen -t ed25519 -C "fife.alan@protonmail.com"
cat ~/.ssh/id_ed25519.pub
```

Add the printed key to GitHub -> Settings -> SSH keys.

### 4. Clone the repo

Run on the new laptop:

```bash
git clone "$GIT_REPO" "$REPO"
cd "$REPO"
```

### 5. Create the editor key

Run on the new laptop:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 0600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt
```

Copy the printed `age1...` public key.

### 6. Add the editor key to the repo inventory

Run on any machine with the repo checked out:

```bash
cd "$REPO"
nano secrets/keys.nix
```

Add the new public key under `editors` and make sure the correct
`creationRules` entry includes `"$EDITOR_NAME"`.

Example shape:

```nix
editors = {
  alan-laptop = {
    recipient = "age1...";
    description = "Editor key kept on alan-laptop in ~/.config/sops/age/keys.txt.";
  };
};

creationRules = [
  {
    pathRegex = "^secrets/.*\\.ya?ml$";
    editors = [ "alan-laptop" ];
    hosts = [ "randy-big-nixos" "alan-big-nixos" ];
  }
];
```

### 7. Rekey the secrets so the laptop can decrypt

Run on an existing machine that can already decrypt secrets:

```bash
cd "$REPO"
./scripts/generate-sops-config.sh
./scripts/update-sops-keys.sh
git add secrets/keys.nix .sops.yaml secrets/secrets.yaml
git commit -m "Add $EDITOR_NAME editor key"
git push
```

### 8. Pull the updated repo onto the new laptop

Run on the new laptop:

```bash
cd "$REPO"
git pull
./scripts/generate-sops-config.sh --check
```

### 9. Confirm `sops` can decrypt

Run on the new laptop:

```bash
sops secrets/secrets.yaml
```

## Notes

### First 3-Node Cluster Bootstrap

Once `alan-big-nixos`, `randy-big-nixos`, and `alan-node-nixos` all exist in
the repo and have their Tailscale and `sops` secrets in place, do the first
`etcd` rollout like this.

Run on your editor machine:

```bash
cd "$REPO"
git push
```

Then rebuild all three cluster nodes without a long gap between them:

```bash
ssh buddia@alan-big-nixos 'cd ~/.nixos && git pull --ff-only && if command -v doas >/dev/null 2>&1; then doas nixos-rebuild switch --flake ~/.nixos#alan-big-nixos; else sudo nixos-rebuild switch --flake ~/.nixos#alan-big-nixos; fi'
ssh buddia@randy-big-nixos 'cd ~/.nixos && git pull --ff-only && if command -v doas >/dev/null 2>&1; then doas nixos-rebuild switch --flake ~/.nixos#randy-big-nixos; else sudo nixos-rebuild switch --flake ~/.nixos#randy-big-nixos; fi'
ssh buddia@alan-node-nixos 'cd ~/.nixos && git pull --ff-only && if command -v doas >/dev/null 2>&1; then doas nixos-rebuild switch --flake ~/.nixos#alan-node-nixos; else sudo nixos-rebuild switch --flake ~/.nixos#alan-node-nixos; fi'
```

The first bootstrap still uses `initialClusterState = "new"`, but `etcd` is now
allowed to wait indefinitely for quorum instead of being killed by the default
systemd startup timeout. The important thing is that all three nodes eventually
land on the same config.

After that, verify the control plane from any node:

```bash
alanix-etcd-local-health
alanix-etcd-health
alanix-etcd-members
```

If you change the cluster transport addresses after `etcd` has already been
bootstrapped, `etcd` will still have the old peer URLs in `/var/lib/etcd`. In
that case, rebuild all nodes onto the new config first, then stop `etcd` on
all nodes, remove `/var/lib/etcd`, and start `etcd` again on all three nodes.

For the current repo state, that reset is safe because `etcd` is only acting as
control-plane groundwork and is not yet the source of truth for application
data.

The failover controller is also now `etcd`-driven. Useful commands on any node:

```bash
alanix-failover-status
systemctl status forgejo-role-controller
systemctl status immich-role-controller
```

- `.sops.yaml` is generated from `secrets/keys.nix`. Do not hand-edit
  `.sops.yaml`.
- When recipients change, always run:

```bash
./scripts/generate-sops-config.sh
./scripts/update-sops-keys.sh
```

- Server hosts explicitly disable idle suspend and sleep in
  `hosts/common/core/server-power.nix` so a graphical session cannot suspend a
  machine that is meant to stay online.

- If you later split secrets by scope, narrow the `creationRules` in
  `secrets/keys.nix` so each host only gets the secrets it actually needs.
