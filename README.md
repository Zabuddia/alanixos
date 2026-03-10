# SOPS Workflow

This repo uses `sops-nix` with dedicated `age` keys and a generated `.sops.yaml`.

The intended model is:
- Editor keys live on laptops/workstations and are used to edit or rekey secrets.
- Host keys live only on servers at `/var/lib/sops-nix/key.txt` and are used only for runtime decryption.
- Server keys are never copied into a user profile just so `sops` can edit files.

## Source of Truth

These files define the workflow:
- `secrets/keys.nix`: named editor keys, named host keys, and the creation rules.
- `secrets/render-sops-config.nix`: renders `.sops.yaml` from `secrets/keys.nix`.
- `scripts/generate-sops-config.sh`: regenerates `.sops.yaml`.
- `scripts/update-sops-keys.sh`: regenerates `.sops.yaml` and runs `sops updatekeys` on managed secret files.

Use this any time recipients change:

```bash
./scripts/generate-sops-config.sh
./scripts/update-sops-keys.sh
```

If you only want to verify the generated file is current:

```bash
./scripts/generate-sops-config.sh --check
```

## Day-to-Day Rules

1. Keep at least one editor key on a machine you control.
2. Give each server its own dedicated `age` key.
3. Only put a host on the rules for secrets that host should decrypt.
4. After changing recipients, always run `./scripts/update-sops-keys.sh` from a machine that already has an editor key.

The current repo still uses one broad rule for `secrets/*.yaml`. That is fine as a starting point, but the more real-world pattern is to split secrets by scope and narrow the host list per rule as you grow.

## Add an Editor Laptop

Generate a dedicated editor key on the laptop:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 0600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt
```

Take the printed `age1...` public key and add it under `editors` in `secrets/keys.nix`, then include that editor name in the appropriate `creationRules`.

Apply the change:

```bash
./scripts/generate-sops-config.sh
./scripts/update-sops-keys.sh
git add secrets/keys.nix .sops.yaml secrets/secrets.yaml
git commit -m "Add editor sops recipient"
```

## Add a Server

Generate a dedicated runtime key on the server:

```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 0400 /var/lib/sops-nix/key.txt
sudo chown root:root /var/lib/sops-nix/key.txt
sudo age-keygen -y /var/lib/sops-nix/key.txt
```

Take the printed `age1...` public key and add it under `hosts` in `secrets/keys.nix`, then add that host name to the right `creationRules`.

From an editor machine that can already decrypt secrets:

```bash
./scripts/generate-sops-config.sh
./scripts/update-sops-keys.sh
git add secrets/keys.nix .sops.yaml secrets/secrets.yaml
git commit -m "Add host sops recipient"
```

Then deploy the server normally. Do not copy `/var/lib/sops-nix/key.txt` into `~/.config/sops/age/keys.txt`.

## Fresh Server Bootstrap

For a brand-new NixOS machine that needs to join this repo:

1. Install NixOS and create your user.
2. Install basic tooling:

```bash
nix-shell -p git sops age
```

3. Clone the repo:

```bash
git clone git@github.com:Zabuddia/alanixos.git ~/.nixos
cd ~/.nixos
```

4. Generate the host key in `/var/lib/sops-nix/key.txt` as shown above.
5. Add that public key to `secrets/keys.nix` from an editor machine.
6. Run `./scripts/update-sops-keys.sh` on the editor machine and push the result.
7. Pull the updated repo on the new server.
8. Copy the hardware config into place:

```bash
cp /etc/nixos/hardware-configuration.nix ~/.nixos/hosts/randy-big-nixos/hardware-configuration.nix
```

9. Rebuild:

```bash
sudo nixos-rebuild switch --flake ~/.nixos#randy-big-nixos
```

## Editing Secrets

Use `sops` from a machine that has an editor private key:

```bash
sops secrets/secrets.yaml
```

If you later split secrets into files like `secrets/hosts/<host>.yaml` or `secrets/services/<name>.yaml`, add narrower rules in `secrets/keys.nix` and keep host recipients scoped to only what they need.
