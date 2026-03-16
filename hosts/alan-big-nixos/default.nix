{ hostname, config, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ../../modules/roles/server.nix
    ../../modules/services/bitcoin.nix
    ../../modules/services/filebrowser.nix
  ];

  alanix.ddns = {
    enable = true;
    provider = "cloudflare";
    domains = [ "alan-big-nixos-wg.fifefin.com" ];
    credentialsFile = config.sops.templates."cloudflare-env".path;
  };

  alanix.wireguard = {
    enable = true;
    vpnIP = "10.100.0.1";
    endpoint = "alan-big-nixos-wg.fifefin.com:51820";
    publicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
    privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
  };

  alanix.desktop.enable = true;

  swapDevices = [
    { device = "/swapfile"; size = 8192; }
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
