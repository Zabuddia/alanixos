{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster.settings;
in
{
  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = cluster.timezone;
  system.stateVersion = cluster.stateVersion;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.timesyncd.enable = true;

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
