# alanixos

## Install NixOS

1. Install NixOS.
2. During install:
   - Set the hostname to match one of the directories in `hosts/`
   - Create a temporary user (this config will manage users later)
3. Boot into the installed system.

---

## Clone this repository

```bash
nix-shell -p git
ssh-keygen -t ed25519 -C "fife.alan@protonmail.com"
cat ~/.ssh/id_ed25519.pub 
mkdir ~/.nixos
git clone git@github.com:Zabuddia/alanixos.git ~/.nixos
```

---

## SOPS (age) setup

Generate an age key (as root):

```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 0400 /var/lib/sops-nix/key.txt
sudo chown root:root /var/lib/sops-nix/key.txt
```

Make the key available to your user (for editing secrets):

```bash
mkdir -p ~/.config/sops/age
sudo cp /var/lib/sops-nix/key.txt ~/.config/sops/age/keys.txt
sudo chown -R $USER:$(id -gn) ~/.config/sops
chmod 0600 ~/.config/sops/age/keys.txt
```

Get the public age key:

```bash
age-keygen -y ~/.config/sops/age/keys.txt
```

Use this public key in the sops configuration to encrypt secrets.

Edit secrets:

```bash
sops secrets/secrets.yaml
```

---

## Rebuild system

From the repo root:

```bash
sudo nixos-rebuild switch --flake .#<hostname>
```
