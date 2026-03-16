{ pkgs, hostname, config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ./users.nix
    ./wireguard.nix
    ../../modules/desktop
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
  ];

  alanix.desktop.enable = true;

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
  programs.nix-ld.enable = true;

  # Networking
  networking.networkmanager.enable = true;

  # Firewall
  networking.firewall.enable = true;

  # Swap
  swapDevices = [
    { device = "/swapfile"; size = 8192; }
  ];

  # Cloudflare DDNS
  services.cloudflare-ddns = {
    enable = true;
    domains = [ "randy-big-nixos-wg.fifefin.com" ];
    credentialsFile = config.sops.templates."cloudflare-env".path;
    provider.ipv6 = "none";
  };

  # Basic tools
  environment.systemPackages = with pkgs; [
    age
    caddy
    curl
    git
    htop
    jq
    restic
    sops
    tree
    wget
  ];
}
