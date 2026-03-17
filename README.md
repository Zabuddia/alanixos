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
sudo nixos-rebuild switch --flake ~/.nixos#<hostname>
```

---

## Step 10 — Reboot

```bash
reboot
```
