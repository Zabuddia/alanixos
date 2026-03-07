{ pkgs, hostname, config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../common/secrets.nix
    ../common/users.nix
    ../common/wireguard.nix
    ../common/filebrowser.nix
    ../common/gitea.nix
    ../common/dynamic-dns.nix
    ../common/filebrowser-failover.nix
    ../common/gitea-failover.nix
    ../common/filebrowser-backups.nix
    ../common/gitea-backups.nix
    ../../modules/cosmic.nix
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
    ../../modules/bitcoin.nix
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
    wireguard-tools
    git
    curl
    wget
    htop
    nano
    tree
  ];
}
