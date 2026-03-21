# NixOS Bootstrap Guide

How to set up a new machine from this flake repo.

- User: `buddia`
- Repo: `https://github.com/Zabuddia/alanixos`
- Flake path: `~/.nixos`
- Secrets: `secrets/secrets.yaml` (encrypted with age via sops-nix)
- Prerequisite: another machine that is already set up and can decrypt secrets

---

## Step 1 — Fresh NixOS install

Install NixOS normally, create user `buddia`, enable networking, and boot in.

---

## Step 2 — Enter a shell with required tools

```bash
nix-shell -p git sops age
```

---

## Step 3 — Clone the repo

SSH keys are deployed by sops-nix after the first rebuild, so use HTTPS for the initial clone:

```bash
git clone https://github.com/Zabuddia/alanixos.git ~/.nixos
cd ~/.nixos
```

---

## Step 4 — Generate the machine's sops age key

This key is used by sops-nix to decrypt secrets at boot. It lives at `/var/lib/sops-nix/key.txt` and is root-only.

```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 0400 /var/lib/sops-nix/key.txt
sudo chown root:root /var/lib/sops-nix/key.txt
```

Print the public key — you'll need it in the next step:

```bash
sudo age-keygen -y /var/lib/sops-nix/key.txt
```

**Workstations only** — also copy the key for `buddia` so you can run `sops` without sudo to edit secrets:

```bash
mkdir -p ~/.config/sops/age
sudo cp /var/lib/sops-nix/key.txt ~/.config/sops/age/keys.txt
sudo chown buddia:users ~/.config/sops/age/keys.txt
chmod 0600 ~/.config/sops/age/keys.txt
```

---

## Step 5 — Add the key to the repo (on this machine)

Edit `secrets/keys.nix` and add the new machine's `age1...` public key, then regenerate `.sops.yaml`:

```bash
vim secrets/keys.nix
bash ./scripts/update-sops-config
git add .sops.yaml
git commit -m "Add <hostname> age recipient"
git push
```

---

## Step 6 — Re-encrypt secrets (on another already-set-up machine)

```bash
cd ~/.nixos
git pull
sops updatekeys --yes secrets/secrets.yaml

# If the already-set-up machine is not a workstation then do:
sudo SOPS_AGE_KEY_FILE="/var/lib/sops-nix/key.txt" sops updatekeys --yes secrets/secrets.yaml

git add secrets/secrets.yaml
git commit -m "Re-encrypt secrets for <hostname>"
git push
```

---

## Step 7 — Pull the updated secrets (back on the new machine)

```bash
cd ~/.nixos
git pull
```

---

## Step 8 — Copy hardware config

```bash
cp /etc/nixos/hardware-configuration.nix ~/.nixos/hosts/<hostname>/hardware-configuration.nix
```

---

## Step 9 — Rebuild

```bash
nix flake check --no-build
sudo nixos-rebuild switch --flake ~/.nixos#<hostname>
```

---

## Step 10 — Reboot

```bash
reboot
```

## Connect to eduroam

```bash
nmcli connection add type wifi ifname wlo1 con-name eduroam ssid eduroam \
    wifi-sec.key-mgmt wpa-eap \
    802-1x.eap peap \
    802-1x.identity "your_netid@byu.edu" \
    802-1x.password "your_password" \
    802-1x.phase2-auth mschapv2
```

---

## How this repo fits together

- `flake.nix` finds every directory under `hosts/`, imports each host once, creates every `nixosConfiguration`, and exposes repo-wide `checks` so `nix flake check --no-build` validates all hosts at once.
- `lib/mkHost.nix` validates that `hosts/<hostname>/default.nix` defines top-level `system` and `module`, then creates the NixOS system with the shared module tree and special args like `hostname` and `allHosts`.
- `hosts/<hostname>/default.nix` is the source of truth for that machine. Host files are intentionally explicit, even when that means some repetition across machines.
- `modules/default.nix` is the shared entrypoint. It pulls together the reusable `alanix.*` modules.
- `modules/pkgs.nix` creates `pkgs-unstable` from the same nixpkgs policy as the host, so things like `allowUnfree` stay consistent across stable and unstable packages.
- `modules/system.nix` handles machine-wide base settings like boot, timezone, locale, firewall, and system packages.
- `modules/users.nix` handles users and Home Manager. It works like `modules/system.nix`: it defines `alanix.users` and maps that into normal NixOS and Home Manager options.
- `alanix.users.accounts.<name>.home` is just the base Home Manager block for that user: directory, state version, files, and extra packages.
- `modules/users/` implements per-account user features like `git`, `sh`, `ssh`, `desktop`, `chromium`, `librewolf`, and `vscode`, which are enabled directly as `alanix.users.accounts.<name>.<feature>`.
- `alanix.wireguard.peers` stays explicit in each host file, so VPN topology is declared where the rest of the host lives.
- `modules/desktop/`, `modules/network/`, and `modules/services/` implement the actual feature modules that the host files turn on with `alanix.*`.

## Why a host file starts like this

```nix
system = "x86_64-linux";

module = { config, pkgs, ... }: let
  systemPackages = with pkgs; [
    age
    caddy
    curl
    git
  ];

  wireguard = {
    enable = true;
    vpnIP = "10.100.0.4";
    endpoint = "alan-laptop-nixos-wg.fifefin.com:51820";
    publicKey = "...";
    listenPort = 51820;
    peers = [ "alan-big-nixos" "randy-big-nixos" "alan-framework" ];
  };
in {
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
  ];
```

- `system = "x86_64-linux";` is not a normal NixOS option. It is host metadata that the flake needs before module evaluation so it knows which platform and package set to instantiate.
- `module = { config, pkgs, ... }:` is the actual NixOS module for that host. Everything inside it is the machine configuration.
- `let ... in { ... }` is just local host-file structure to keep repeated values readable.
- `imports = [ ./hardware-configuration.nix ./secrets.nix ];` pulls in the generated hardware config and the host-specific secrets declarations. Everything else for that machine should be expressed as `alanix.*` in the same file.
