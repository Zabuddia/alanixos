# Fresh NixOS + Flake + sops-nix Bootstrap Guide

This document describes **every command** needed to take a **brand-new NixOS install**
and rebuild it from an existing flake repo that uses **sops-nix with age**.

Assumptions:
- User: `buddia`
- Repo: `git@github.com:Zabuddia/alanixos.git`
- Flake path: `~/.nixos`
- Host: `randy-big-nixos`
- Secrets: `secrets/secrets.yaml`
- Encryption: **age**
- You already have **another computer** that can decrypt secrets

---

## PHASE 0 — Fresh NixOS Install
1. Install NixOS normally
2. Create user `buddia`
3. Enable networking
4. Boot into the system

---

## PHASE 1 — Enable tools
```bash
nix-shell -p git sops age
```

---

## PHASE 2 — Git access (SSH)
```bash
ssh-keygen -t ed25519 -C "fife.alan@protonmail.com"
cat ~/.ssh/id_ed25519.pub
# Add key to GitHub → Settings → SSH keys
```

---

## PHASE 3 — Clone flake repo
```bash
git clone git@github.com:Zabuddia/alanixos.git ~/.nixos
cd ~/.nixos
```

---

## PHASE 4 — Generate machine sops key
```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 0400 /var/lib/sops-nix/key.txt
sudo chown root:root /var/lib/sops-nix/key.txt
sudo age-keygen -y /var/lib/sops-nix/key.txt
```

Copy the printed `age1...` public key.

## PHASE 5 — Make the key available to your user (for editing secrets):

```bash
mkdir -p ~/.config/sops/age
sudo cp /var/lib/sops-nix/key.txt ~/.config/sops/age/keys.txt
sudo chown -R $USER:$(id -gn) ~/.config/sops
chmod 0600 ~/.config/sops/age/keys.txt
```

---

## PHASE 6 — Add key to .sops.yaml
Edit `.sops.yaml` and add the new key.

```bash
git add .sops.yaml
git commit -m "Add randy-big-nixos age recipient"
git push
```

---

## PHASE 7 — Re-encrypt secrets (OTHER computer)
```bash
cd ~/.nixos
git pull
sops updatekeys secrets/secrets.yaml
git add secrets/secrets.yaml
git commit -m "Re-encrypt secrets for randy-big-nixos"
git push
```

---

## PHASE 8 — Pull updated secrets (NEW machine)
```bash
cd ~/.nixos
git pull
```

---

## PHASE 9 — Hardware config
```bash
cp /etc/nixos/hardware-configuration.nix ~/.nixos/hosts/randy-big-nixos/hardware-configuration.nix
```


---

## PHASE 10 — Rebuild
```bash
sudo nixos-rebuild switch --flake ~/.nixos#randy-big-nixos
```

---

## PHASE 11 — Reboot
```bash
reboot
```

---