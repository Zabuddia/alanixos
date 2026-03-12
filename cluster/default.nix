{
  cluster = {
    domain = "fifefin.com";
    timezone = "America/Denver";
    stateVersion = "25.11";
    activeNode = "randy-big-nixos";

    dns = {
      provider = "cloudflare";
      apiTokenSecret = "cloudflare/api-token";
      publicIpv4Urls = [
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
      ];
      endpointRecord = {
        proxied = false;
        ttl = 60;
        timerConfig = {
          OnBootSec = "30s";
          OnUnitInactiveSec = "5m";
          AccuracySec = "30s";
          RandomizedDelaySec = "0";
          Persistent = true;
        };
      };
      serviceRecords = {
        proxied = false;
        ttl = 60;
        timerConfig = {
          OnBootSec = "30s";
          OnUnitInactiveSec = "2m";
          AccuracySec = "30s";
          RandomizedDelaySec = "0";
          Persistent = true;
        };
      };
    };

    wireguard = {
      interface = "wg0";
      subnet = "10.100.0.0/24";
      listenPort = 51820;
      privateKeySecretPrefix = "wireguard-private-keys";
    };

    backupDefaults = {
      sshPrivateKeySecret = "cluster/sync-private-key";
      sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFqBvDH10XQLN1srCL3U92KUZcXn0f+PkYPKhWfQehf7 filebrowser-failover-sync";
      sshUser = "cluster-backup";
      passwordSecret = "restic/cluster-password";
      incomingBaseDir = "/var/backups/restic";
      timerConfig = {
        OnActiveSec = "15m";
        OnUnitInactiveSec = "15m";
        AccuracySec = "1m";
        RandomizedDelaySec = "0";
        Persistent = true;
      };
      prunePolicy = [
        "--keep-hourly 24"
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
    };
  };

  nodes = {
    alan-big-nixos = {
      system = "x86_64-linux";
      priority = 20;
      vpnIp = "10.100.0.1";
      wireguardPublicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
      endpointHost = "alan-big-nixos-wg.fifefin.com";
      publicIngress = true;
      receiveBackups = true;
      torCapable = true;
    };

    randy-big-nixos = {
      system = "x86_64-linux";
      priority = 10;
      vpnIp = "10.100.0.2";
      wireguardPublicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
      endpointHost = "randy-big-nixos-wg.fifefin.com";
      publicIngress = true;
      receiveBackups = true;
      torCapable = true;
    };
  };

  services = {
    filebrowser = {
      enable = true;
      uid = 45000;
      gid = 45000;
      backendPort = 8088;

      state = {
        stateDir = "/var/lib/filebrowser";
        rootDir = "/srv/filebrowser";
        databasePath = "/var/lib/filebrowser/filebrowser.db";
        persistentPaths = [
          "/var/lib/filebrowser"
          "/srv/filebrowser"
        ];
      };

      access = {
        wan = {
          enable = true;
          domain = "filebrowser.fifefin.com";
        };

        wireguard = {
          enable = true;
          port = 8089;
        };

        tor = {
          enable = true;
          serviceName = "filebrowser";
          version = 3;
          httpLocalPort = 18088;
          httpVirtualPort = 80;
          httpsLocalPort = 18443;
          httpsVirtualPort = 443;
          secretKeySecret = "tor/filebrowser/secret-key-base64";
        };
      };

      bootstrap = {
        users = {
          admin = {
            admin = true;
            scope = ".";
            passwordSecret = "service-passwords/admin";
          };

          buddia = {
            admin = false;
            scope = "users/buddia";
            passwordSecret = "service-passwords/buddia";
          };
        };
      };

      backup = {
        enable = true;
        paths = [
          "/var/lib/filebrowser"
          "/srv/filebrowser"
        ];
        timerConfig = {
          OnActiveSec = "10m";
          OnUnitInactiveSec = "10m";
          AccuracySec = "30s";
          RandomizedDelaySec = "0";
          Persistent = true;
        };
        restoreCommand = "";
      };
    };

    forgejo = {
      enable = true;
      uid = 45010;
      gid = 45010;
      backendPort = 3000;

      state = {
        stateDir = "/var/lib/forgejo";
        persistentPaths = [ "/var/lib/forgejo" ];
      };

      access = {
        wan = {
          enable = true;
          domain = "forgejo.fifefin.com";
          canonicalRootUrl = "https://forgejo.fifefin.com/";
        };

        wireguard = {
          enable = true;
          port = 8090;
        };

        tor = {
          enable = true;
          serviceName = "forgejo";
          version = 3;
          httpLocalPort = 13000;
          httpVirtualPort = 80;
          httpsLocalPort = 13443;
          httpsVirtualPort = 443;
          secretKeySecret = "tor/forgejo/secret-key-base64";
        };
      };

      bootstrap = {
        allowRegistration = false;
        users = {
          buddia = {
            admin = true;
            email = "fife.alan@protonmail.com";
            fullName = "Alan Fife";
            mustChangePassword = false;
            passwordSecret = "service-passwords/buddia";
          };
        };
      };

      backup = {
        enable = true;
        paths = [ "/var/lib/forgejo" ];
        timerConfig = {
          OnActiveSec = "5m";
          OnUnitInactiveSec = "5m";
          AccuracySec = "30s";
          RandomizedDelaySec = "0";
          Persistent = true;
        };
        restoreCommand = "";
      };
    };

    immich = {
      enable = true;
      uid = 45030;
      gid = 45030;
      backendPort = 2283;

      state = {
        stateDir = "/var/lib/immich";
        databaseDumpPath = "/var/lib/immich/_cluster-backup/immich.sql";
        persistentPaths = [ "/var/lib/immich" ];
      };

      access = {
        wan = {
          enable = true;
          domain = "immich.fifefin.com";
        };

        wireguard = {
          enable = true;
          port = 8091;
        };

        tor = {
          enable = true;
          serviceName = "immich";
          version = 3;
          httpLocalPort = 18283;
          httpVirtualPort = 80;
          httpsLocalPort = 18683;
          httpsVirtualPort = 443;
          secretKeySecret = "tor/immich/secret-key-base64";
        };
      };

      bootstrap = {
        adminEmail = "fife.alan@protonmail.com";
        adminPasswordSecret = "service-passwords/buddia";
        users = {
          buddia = {
            email = "fife.alan@protonmail.com";
            displayName = "Alan Fife";
            isAdmin = true;
            shouldChangePassword = false;
            passwordSecret = "service-passwords/buddia";
          };
        };
      };

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

      backup = {
        enable = true;
        paths = [ "/var/lib/immich" ];
        timerConfig = {
          OnActiveSec = "1h";
          OnUnitInactiveSec = "1h";
          AccuracySec = "5m";
          RandomizedDelaySec = "0";
          Persistent = true;
        };
        prepareCommand = ''
          install -d -m 0750 -o root -g root /var/lib/immich/_cluster-backup
          runuser -u postgres -- pg_dump \
            --clean \
            --if-exists \
            --no-owner \
            immich > /var/lib/immich/_cluster-backup/immich.sql
          chown root:root /var/lib/immich/_cluster-backup/immich.sql
          chmod 0600 /var/lib/immich/_cluster-backup/immich.sql
        '';
        restoreCommand = ''
          runuser -u postgres -- dropdb --if-exists immich
          runuser -u postgres -- createdb --owner=immich immich
          runuser -u postgres -- psql --dbname=immich --set=ON_ERROR_STOP=1 <<'SQL'
          SET ROLE immich;
          \i /var/lib/immich/_cluster-backup/immich.sql
          SQL
          runuser -u postgres -- psql --dbname=immich --set=ON_ERROR_STOP=1 <<'SQL'
          REASSIGN OWNED BY postgres TO immich;
          ALTER DATABASE immich OWNER TO immich;
          ALTER SCHEMA public OWNER TO immich;
          SQL
        '';
      };
    };

    invidious = {
      enable = true;
      uid = 45040;
      gid = 45040;
      backendPort = 3100;

      state = {
        stateDir = "/var/lib/invidious";
        databaseDumpPath = "/var/lib/invidious/_cluster-backup/invidious.sql";
        persistentPaths = [ "/var/lib/invidious" ];
      };

      access = {
        wan = {
          enable = true;
          domain = "invidious.fifefin.com";
        };

        wireguard = {
          enable = true;
          port = 8092;
        };

        tor = {
          enable = true;
          serviceName = "invidious";
          version = 3;
          httpLocalPort = 18300;
          httpVirtualPort = 80;
          httpsLocalPort = 18743;
          httpsVirtualPort = 443;
          secretKeySecret = "tor/invidious/secret-key-base64";
        };
      };

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

      cookieDomain = null;

      database = {
        createLocally = true;
        host = null;
        port = 5432;
        passwordSecret = null;
      };

      companion = {
        enable = true;
        listenAddress = "127.0.0.1:2999";
      };

      bootstrap = {
        hmacKeySecret = "invidious/hmac-key";
        users = {
          buddia = {
            passwordSecret = "service-passwords/buddia";
          };
        };
      };

      backup = {
        enable = true;
        paths = [ "/var/lib/invidious" ];
        timerConfig = {
          OnActiveSec = "10m";
          OnUnitInactiveSec = "10m";
          AccuracySec = "30s";
          RandomizedDelaySec = "0";
          Persistent = true;
        };
        prepareCommand = ''
          install -d -m 0750 -o root -g root /var/lib/invidious/_cluster-backup
          runuser -u postgres -- pg_dump \
            --clean \
            --if-exists \
            --no-owner \
            invidious > /var/lib/invidious/_cluster-backup/invidious.sql
          chown root:root /var/lib/invidious/_cluster-backup/invidious.sql
          chmod 0600 /var/lib/invidious/_cluster-backup/invidious.sql
        '';
        restoreCommand = ''
          runuser -u postgres -- dropdb --if-exists invidious
          runuser -u postgres -- createdb --owner=invidious invidious
          runuser -u postgres -- psql --dbname=invidious --set=ON_ERROR_STOP=1 <<'SQL'
          SET ROLE invidious;
          \i /var/lib/invidious/_cluster-backup/invidious.sql
          SQL
          runuser -u postgres -- psql --dbname=invidious --set=ON_ERROR_STOP=1 <<'SQL'
          REASSIGN OWNED BY postgres TO invidious;
          ALTER DATABASE invidious OWNER TO invidious;
          ALTER SCHEMA public OWNER TO invidious;
          SQL
        '';
      };
    };
  };
}
