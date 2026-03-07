{ config, ... }:
{
  imports = [
    ../../modules/cluster.nix
    ../../modules/service-failover.nix
    ../../modules/service-backups.nix
  ];

  alanix.cluster = {
    domain = "fifefin.com";
    wgSubnetCIDR = "10.100.0.0/24";
    dns = {
      provider = "cloudflare";
      apiTokenSecret = "cloudflare/api-token";
    };

    nodes = {
      alan-big-nixos = {
        vpnIP = "10.100.0.1";
        priority = 20;
        wireguardPublicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
        wireguardEndpointHost = "alan-big-nixos-wg.fifefin.com";
      };

      randy-big-nixos = {
        vpnIP = "10.100.0.2";
        priority = 10;
        wireguardPublicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
        wireguardEndpointHost = "randy-big-nixos-wg.fifefin.com";
      };
    };

    services.filebrowser = {
      backendPort = 8088;
      uid = 45000;
      gid = 45000;
      backups = {
        enable = true;
        passwordSecret = "restic/cluster-password";
        repositoryBasePath = "/var/backups/restic/filebrowser";
        schedule = "hourly";
        randomizedDelaySec = "10m";
        pruneOpts = [
          "--keep-hourly 24"
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };
      wanAccess = {
        enable = true;
        domain = "filebrowser.fifefin.com";
        openFirewall = true;
      };
      wireguardAccess = {
        enable = true;
        port = 8089;
      };
      torAccess = {
        enable = true;
        onionServiceName = "filebrowser";
        localPort = 18088;
        virtualPort = 80;
        version = 3;
        secretKeySecret = null;
      };
      syncPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFqBvDH10XQLN1srCL3U92KUZcXn0f+PkYPKhWfQehf7 filebrowser-failover-sync";
    };

    services.gitea = {
      enable = true;
      backendPort = 3000;
      stateDir = "/var/lib/gitea";
      uid = 45010;
      gid = 45010;
      dataPaths = [ "/var/lib/gitea" ];
      wanAccess = {
        enable = true;
        domain = "gitea.fifefin.com";
        openFirewall = true;
        canonicalRootUrl = null;
      };
      wireguardAccess = {
        enable = true;
        port = 8090;
      };
      torAccess = {
        enable = true;
        onionServiceName = "gitea";
        localPort = 13000;
        virtualPort = 80;
        version = 3;
        secretKeySecret = null;
      };
      syncPublicKey = config.alanix.cluster.services.filebrowser.syncPublicKey;
      backups = {
        enable = true;
        passwordSecret = "restic/cluster-password";
        repositoryBasePath = "/var/backups/restic/gitea";
        schedule = "hourly";
        randomizedDelaySec = "10m";
        pruneOpts = [
          "--keep-hourly 24"
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };
    };
  };
}
