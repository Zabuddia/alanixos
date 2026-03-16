{ pkgs, hostname, config, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ../../modules/network/wireguard.nix
    ../../modules/roles/workstation.nix
    ../../modules/services/sunshine.nix
  ];

  alanix.ddns = {
    enable = true;
    provider = "cloudflare";
    domains = [ "alan-laptop-nixos-wg.fifefin.com" ];
    credentialsFile = config.sops.templates."cloudflare-env".path;
  };

  alanix.wireguard = {
    enable = true;
    vpnIP = "10.100.0.4";
    endpoint = "alan-laptop-nixos-wg.fifefin.com:51820";
    publicKey = "U96LblYX6Klccf6yFVmKDQZp4882rSPTWq2wzFmbVV4=";
    privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
  };

  swapDevices = [
    { device = "/swapfile"; size = 8192; }
  ];

  environment.systemPackages = with pkgs; [
    vlc
    ffmpeg
    w_scan2
    nano
  ];
}
