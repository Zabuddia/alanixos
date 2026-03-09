{ config, ... }:
{
  imports = [
    ../../../modules/cluster.nix
    ../../../modules/service-failover.nix
    ../../../modules/service-backups.nix
  ];

  alanix.cluster = {
    domain = "fifefin.com";
    wgSubnetCIDR = "10.100.0.0/24";
    dns = {
      provider = "cloudflare";
      apiTokenSecret = "cloudflare/api-token";
    };
    syncPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFqBvDH10XQLN1srCL3U92KUZcXn0f+PkYPKhWfQehf7 filebrowser-failover-sync";

    nodes = {
      alan-big-nixos = {
        vpnIP = "10.100.0.1";
        priority = 10;
        wireguardPublicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
        wireguardEndpointHost = "alan-big-nixos-wg.fifefin.com";
      };

      randy-big-nixos = {
        vpnIP = "10.100.0.2";
        priority = 20;
        wireguardPublicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
        wireguardEndpointHost = "randy-big-nixos-wg.fifefin.com";
      };
    };

    services.filebrowser = {
      enable = true;
      backendPort = 8088;
      uid = 45000;
      gid = 45000;
      users = {
        admin = {
          passwordSecret = "service-passwords/admin";
          admin = true;
          scope = ".";
        };

        buddia = {
          passwordSecret = "service-passwords/buddia";
          admin = false;
          scope = "users/buddia";
        };
      };
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
        enableHttp = true;
        httpLocalPort = 18088;
        httpVirtualPort = 80;
        enableHttps = true;
        httpsLocalPort = 18443;
        httpsVirtualPort = 443;
        version = 3;
        secretKeySecret = null;
      };
    };

    services.forgejo = {
      enable = true;
      backendPort = 3000;
      stateDir = "/var/lib/forgejo";
      uid = 45010;
      gid = 45010;
      users = {
        buddia = {
          admin = true;
          email = "fife.alan@protonmail.com";
          fullName = "Alan Fife";
          passwordSecret = "service-passwords/buddia";
          mustChangePassword = false;
        };
      };
      dataPaths = [ "/var/lib/forgejo" ];
      wanAccess = {
        enable = true;
        domain = "forgejo.fifefin.com";
        openFirewall = true;
        canonicalRootUrl = null;
      };
      wireguardAccess = {
        enable = true;
        port = 8090;
      };
      torAccess = {
        enable = true;
        onionServiceName = "forgejo";
        enableHttp = true;
        httpLocalPort = 13000;
        httpVirtualPort = 80;
        enableHttps = true;
        httpsLocalPort = 13443;
        httpsVirtualPort = 443;
        version = 3;
        secretKeySecret = null;
      };
      backups = {
        enable = true;
        passwordSecret = "restic/cluster-password";
        repositoryBasePath = "/var/backups/restic/forgejo";
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

    services.invidious = {
      enable = true;
      backendPort = 3100;
      stateDir = "/var/lib/invidious";
      uid = 45040;
      gid = 45040;
      settings = {
        default_user_preferences = {
          default_home = "Popular";
          feed_menu = [
            "Popular"
            "Subscriptions"
            "Playlists"
          ];
        };
      };
      database = {
        createLocally = true;
        host = null;
        port = 5432;
        passwordSecret = null;
      };
      hmacKeySecret = "invidious/hmac-key";
      companion = {
        enable = true;
        listenAddress = "127.0.0.1:2999";
      };
      users = {
        buddia = {
          passwordSecret = "service-passwords/buddia";
        };
      };
      dataPaths = [
        config.alanix.cluster.services.invidious.stateDir
        "/var/lib/postgresql"
      ];
      wanAccess = {
        enable = true;
        domain = "invidious.fifefin.com";
        openFirewall = true;
      };
      wireguardAccess = {
        enable = true;
        port = 8092;
      };
      torAccess = {
        enable = true;
        onionServiceName = "invidious";
        enableHttp = true;
        httpLocalPort = 18300;
        httpVirtualPort = 80;
        enableHttps = true;
        httpsLocalPort = 18743;
        httpsVirtualPort = 443;
        version = 3;
        secretKeySecret = null;
      };
      backups = {
        enable = true;
        passwordSecret = "restic/cluster-password";
        repositoryBasePath = "/var/backups/restic/invidious";
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

    services.immich = {
      enable = true;
      backendPort = 2283;
      stateDir = "/var/lib/immich";
      uid = 45030;
      gid = 45030;
      settings = null;
      environment = { };
      accelerationDevices = [ ];
      database = {
        createLocally = true;
        host = null;
        port = 5432;
        name = "immich";
        user = "immich";
        enableVectorChord = true;
        enableVectors = false;
        passwordSecret = null;
      };
      redis = {
        enable = true;
        host = null;
        port = 0;
      };
      machineLearning = {
        enable = true;
        environment = { };
      };
      dataPaths = [
        config.alanix.cluster.services.immich.stateDir
        "/var/lib/postgresql"
      ];
      wanAccess = {
        enable = true;
        domain = "immich.fifefin.com";
        openFirewall = true;
      };
      wireguardAccess = {
        enable = true;
        port = 8093;
      };
      torAccess = {
        enable = true;
        onionServiceName = "immich";
        enableHttp = true;
        httpLocalPort = 18283;
        httpVirtualPort = 80;
        enableHttps = true;
        httpsLocalPort = 18683;
        httpsVirtualPort = 443;
        version = 3;
        secretKeySecret = null;
      };
      backups = {
        enable = true;
        passwordSecret = "restic/cluster-password";
        repositoryBasePath = "/var/backups/restic/immich";
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

    services.vaultwarden = {
      enable = true;
      backendPort = 8222;
      stateDir = "/var/lib/vaultwarden";
      dbBackend = "sqlite";
      settings = {
        SIGNUPS_ALLOWED = true;
      };
      adminTokenSecret = "vaultwarden/admin-token";
      uid = 45020;
      gid = 45020;
      dataPaths = [ config.alanix.cluster.services.vaultwarden.stateDir ];
      wanAccess = {
        enable = true;
        domain = "vaultwarden.fifefin.com";
        openFirewall = true;
      };
      wireguardAccess = {
        enable = true;
        port = 8091;
      };
      torAccess = {
        enable = true;
        onionServiceName = "vaultwarden";
        enableHttp = true;
        httpLocalPort = 18222;
        httpVirtualPort = 80;
        enableHttps = true;
        httpsLocalPort = 18643;
        httpsVirtualPort = 443;
        version = 3;
        secretKeySecret = null;
      };
      backups = {
        enable = true;
        passwordSecret = "restic/cluster-password";
        repositoryBasePath = "/var/backups/restic/vaultwarden";
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
