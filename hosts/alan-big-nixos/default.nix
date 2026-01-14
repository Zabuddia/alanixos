{ pkgs, hostname, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ./users.nix
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
  ];

  # Identity
  networking.hostName = hostname;
  time.timeZone = "America/Denver";
  system.stateVersion = "25.11";

  # Nix basics
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Firewall
  networking.firewall.enable = true;

  # Swap
  swapDevices = [
    { device = "/swapfile"; size = 8192; }
  ];

  # Basic tools
  environment.systemPackages = with pkgs; [
    age
    sops
    git
    curl
    wget
    htop
    nano
  ];
}