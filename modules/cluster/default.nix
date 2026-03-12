{ ... }:
{
  imports = [
    ./inventory.nix
    ./base.nix
    ./sops.nix
    ./users.nix
    ../ssh.nix
    ./wireguard.nix
    ./role.nix
    ./services.nix
    ./caddy.nix
    ./tor.nix
    ./backups.nix
    ./cloudflare.nix
  ];
}
