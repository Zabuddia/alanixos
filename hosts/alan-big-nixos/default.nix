{ pkgs, hostname, config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ./users.nix
    ./wireguard.nix
    ../../modules/cosmic.nix
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
    ../../modules/bitcoin.nix
    ../../modules/filebrowser.nix
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

  # File browser
  alanix.filebrowser = {
    enable = true;
    listenAddress = "0.0.0.0";
    root = "/srv/filebrowser";
    database = "/var/lib/filebrowser/filebrowser.db";
    users = {
      admin = {
        passwordSecret = "filebrowser-passwords/admin";
        admin = true;
        scope = ".";
      };
      buddia = {
        passwordSecret = "filebrowser-passwords/buddia";
        admin = false;
        scope = "users/buddia";
      };
    };
  };
}