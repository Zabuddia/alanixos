# NixOS Bootstrap Guide

How to set up a new machine from this flake repo.

- User: `buddia`
- Repo: `https://github.com/Zabuddia/alanixos`
- Flake path: `~/.nixos`
- Secrets: `secrets/*.yaml` (encrypted with age via sops-nix)
- Prerequisite: another machine that is already set up and can decrypt secrets

---

## Step 1 — Fresh NixOS install

Install NixOS normally, create user `buddia`, enable networking, and boot in.

---

## Step 2 — Clone the repo

```bash
nix-shell -p git age
git clone https://github.com/Zabuddia/alanixos.git ~/.nixos
cd ~/.nixos
```

---

## Step 3 — Generate the machine's age key and print the public key

```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 0400 /var/lib/sops-nix/key.txt
sudo chown root:root /var/lib/sops-nix/key.txt
sudo age-keygen -y /var/lib/sops-nix/key.txt
```

Copy the `age1...` public key — you'll need it on the already-set-up machine.

---

## Step 4 — Add the key and re-encrypt secrets (on the already-set-up machine)

```bash
cd ~/.nixos
nano secrets/keys.nix          # add the new age1... public key
bash ./scripts/update-sops-config
sops updatekeys --yes secrets/*.yaml
git add secrets/keys.nix .sops.yaml secrets/*.yaml
git commit -m "Add <hostname> age recipient"
git push
```

---

## Step 5 — Pull, copy hardware config, rebuild, and reboot (back on the new machine)

```bash
git pull
cp /etc/nixos/hardware-configuration.nix ~/.nixos/hosts/<hostname>/hardware-configuration.nix
sudo nixos-rebuild switch --flake ~/.nixos#<hostname>
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
- `modules/desktop/`, `modules/network/`, and `modules/services/` implement the actual feature modules that the host files turn on with `alanix.*`.

## Headscale and DERP

`alanix.headscale` runs on the active `home` cluster leader and is exposed at `https://headscale.fifefin.com`. `alanix.headplane` runs beside it as the Headscale admin UI at `https://headplane.fifefin.com`. The cluster DDNS service keeps those names pointed at the current leader, and their state directories are staged and backed up like the other clustered services.

The embedded DERP server is enabled and the public DERP map is disabled by default. Routers that can become the active leader need these inbound forwards to the currently active node:

| Service | Port |
| --- | --- |
| Headscale HTTPS | `443/tcp` |
| ACME HTTP challenge | `80/tcp` |
| DERP STUN | `3478/udp` |

Clients still run `tailscaled`; they point at Headscale with `alanix.tailscale.loginServer = "https://headscale.fifefin.com";`. When `loginServer` is set, `alanix.tailscale` automatically looks for a host-specific preauth key in `secrets/network.yaml`:

```yaml
headscale:
  preauth-keys:
    alan-framework-laptop: ...
```

The generated secret path is `/run/secrets/headscale/preauth-keys/<hostname>`, and NixOS passes it to `tailscale up --auth-key ... --login-server=...` when `tailscaled` needs login. Existing nodes already logged into Tailscale SaaS still need a one-time `sudo tailscale logout` so the autoconnect unit can join Headscale.

Create preauth keys on the active Headscale leader, then store them in SOPS from the repo checkout:

```bash
host=alan-framework-laptop
key="$(sudo headscale preauthkeys create --user 1 --reusable --expiration 87600h --output json | jq -r .key)"
sops set secrets/network.yaml "[\"headscale\"][\"preauth-keys\"][\"$host\"]" "$(jq -Rn --arg key "$key" '$key')"
```

Use `sudo headscale users list` if the `buddia` user ID is not `1`.

Headplane uses Headscale API-key login unless OIDC is configured later. Create an API key on the active Headscale leader, then paste it into Headplane:

```bash
sudo headscale apikeys create --expiration 8760h
```

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

  tailscale = {
    enable = true;
    address = "alan-laptop-nixos";
    acceptRoutes = true;
    loginServer = "https://headscale.fifefin.com";
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
