{ inputs, ... }:

{
  imports = [
    inputs.simple-nixos-mailserver.nixosModule
    ./cluster
    ./pkgs.nix
    ./system.nix
    ./power.nix
    ./users.nix
    ./desktop
    ./network/ssh.nix
    ./network/cloudflare-dns.nix
    ./network/ddns.nix
    ./network/tailscale.nix
    ./network/wifi.nix
    ./network/tor.nix
    ./services
  ];
}
