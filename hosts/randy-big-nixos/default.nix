{ pkgs, hostname, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../common/secrets.nix
    ../common/users.nix
    ../common/wireguard.nix
    ../common/filebrowser.nix
    ../common/forgejo.nix
    ../common/invidious.nix
    ../common/vaultwarden.nix
    ../common/dynamic-dns.nix
    ../common/filebrowser-failover.nix
    ../common/forgejo-failover.nix
    ../common/invidious-failover.nix
    ../common/vaultwarden-failover.nix
    ../common/filebrowser-backups.nix
    ../common/forgejo-backups.nix
    ../common/invidious-backups.nix
    ../common/vaultwarden-backups.nix
    ../../modules/cosmic.nix
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
  ];

  # Identity
  networking.hostName = hostname;
  time.timeZone = "America/Denver";
  system.stateVersion = "25.11";

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Host basics
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix basics
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Networking
  networking.networkmanager.enable = true;

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
    tree
  ];
}
