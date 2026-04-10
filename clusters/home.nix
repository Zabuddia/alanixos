{ config, lib, hostname, ... }:
let
  members = [
    "alan-big-nixos"
    "randy-big-nixos"
    "alan-node"
  ];

  isMember = builtins.elem hostname members;
in
{
  config = lib.mkIf isMember {
    alanix.cluster = {
      enable = true;
      name = "home";
      transport = "tailscale";
      members = members;
      voters = members;
      priority = members;
      addresses = {
        alan-big-nixos = "alan-big-nixos";
        randy-big-nixos = "randy-big-nixos";
        alan-node = "alan-node";
      };

      etcd = {
        heartbeatInterval = "500ms";
        electionTimeout = "5s";
        leaseTtl = "30s";
        renewEvery = "5s";
        acquisitionStep = "5s";
      };

      backup = {
        repoUser = "buddia";
        repoBaseDir = "/var/lib/alanix-backups";
        passwordSecret = "cluster/restic-password";
      };
    };

    alanix.vaultwarden = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8222;
      rootUrl = "https://ajd4rue7nevdl7rceliwqevkqpgd6tizzgxj7e7vzsd56gil5lvs7hid.onion";
      disableRegistration = false;
      backupDir = "/var/backup/vaultwarden";

      expose = {
        tor = {
          enable = true;
          publicPort = 443;
          secretKeyBase64Secret = "tor/vaultwarden/secret-key-base64";
          tls = true;
          tlsName = "ajd4rue7nevdl7rceliwqevkqpgd6tizzgxj7e7vzsd56gil5lvs7hid.onion";
        };

        tailscale = {
          enable = true;
          port = 18222;
          tls = true;
          tlsName = config.alanix.tailscale.address;
        };

        wireguard = {
          enable = true;
          port = 8222;
          tls = true;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "5m";
        maxBackupAge = "15m";
        sameTorAddress = true;
      };
    };
  };
}
