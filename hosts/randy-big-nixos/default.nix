{ pkgs, hostname, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../common/core/secrets.nix
    ../common/core/users.nix
    ../common/core/wireguard.nix
    ../common/services/filebrowser.nix
    ../common/services/forgejo.nix
    ../common/services/invidious.nix
    ../common/services/immich.nix
    ../common/services/vaultwarden.nix
    ../common/services/dashboard.nix
    ../common/core/dynamic-dns.nix
    ../common/services/failover/filebrowser.nix
    ../common/services/failover/dashboard.nix
    ../common/services/failover/forgejo.nix
    ../common/services/failover/invidious.nix
    ../common/services/failover/immich.nix
    ../common/services/failover/vaultwarden.nix
    ../common/services/backups/filebrowser.nix
    ../common/services/backups/forgejo.nix
    ../common/services/backups/invidious.nix
    ../common/services/backups/immich.nix
    ../common/services/backups/vaultwarden.nix
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
    jq
  ];
}
