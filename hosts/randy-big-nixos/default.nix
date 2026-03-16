{ hostname, config, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ../../modules/network/wireguard.nix
    ../../modules/roles/server.nix
  ];

  alanix.ddns = {
    enable = true;
    provider = "cloudflare";
    domains = [ "randy-big-nixos-wg.fifefin.com" ];
    credentialsFile = config.sops.templates."cloudflare-env".path;
  };

  alanix.wireguard = {
    enable = true;
    vpnIP = "10.100.0.2";
    endpoint = "randy-big-nixos-wg.fifefin.com:51820";
    publicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
    privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
  };

  alanix.desktop.enable = true;

  swapDevices = [
    { device = "/swapfile"; size = 8192; }
  ];
}
