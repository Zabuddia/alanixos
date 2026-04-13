{ config, lib, hostname, ... }:
let
  members = [
    "alan-big-nixos"
    "alan-optiplex"
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
        alan-optiplex = "alan-optiplex";
        alan-node = "alan-node";
      };

      etcd = {
        bootstrapGeneration = 2;
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

      dashboard = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9842;
        recentEvents = 40;

        expose = {
          tailscale = {
            enable = true;
            port = 19842;
          };

          wireguard = {
            enable = true;
            port = 9842;
          };

          tor = {
            enable = true;
            publicPort = 80;
            secretKeyBase64Secret = "tor/cluster-dashboard/${hostname}/secret-key-base64";
            hostname =
              if hostname == "alan-big-nixos" then "uu6th6s6ry55vqdp7dbt6znbyedvgeqlmat2venoxkyijq5qk3lipiad.onion"
              else if hostname == "alan-node" then "u7pemgmtbljkrsc2dyqivx7u4kpy76ajf7hmsnlubmhs33uo4tw5txid.onion"
              else if hostname == "alan-optiplex" then "6tkxmjarbepvvy5wrlslbarhfkkowmuttnade55tlpsnd2noy44dnzid.onion"
              else null;
          };
        };
      };
    };

    alanix.users.accounts.buddia.extraGroups = [ "filebrowser" ];

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      listenPort = 22000;
      folderSets = [ "jellyfin-media" "filebrowser-files" ];
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
          hostname = "ajd4rue7nevdl7rceliwqevkqpgd6tizzgxj7e7vzsd56gil5lvs7hid.onion";
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

    alanix.forgejo = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 3000;
      rootUrl = "http://${config.alanix.tailscale.address}:13000/";
      backupDir = "/var/backup/forgejo";

      expose = {
        tailscale = {
          enable = true;
          port = 13000;
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/forgejo/secret-key-base64";
          hostname = "v75vursfye2nc52psierh35xpeury5x7yxfkdamr3i76vuh3rlh42fyd.onion";
        };

        wireguard = {
          enable = true;
          port = 3000;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "5m";
        maxBackupAge = "15m";
      };

      users.buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        passwordSecret = "forgejo-passwords/buddia";
      };
    };

    alanix.filebrowser = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8088;
      root = "/srv/filebrowser";
      database = "/var/lib/filebrowser/filebrowser.db";
      backupDir = "/var/backup/filebrowser";

      expose = {
        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/filebrowser/secret-key-base64";
        };

        tailscale = {
          enable = true;
          address = config.alanix.tailscale.address;
          port = 8088;
        };

        wireguard = {
          enable = true;
          port = 8088;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "15m";
        maxBackupAge = "1h";
      };

      users = {
        admin = {
          admin = true;
          scope = ".";
          passwordSecret = "filebrowser-passwords/admin";
        };

        buddia = {
          admin = false;
          scope = "users/buddia";
          passwordSecret = "filebrowser-passwords/buddia";
        };
      };
    };

    alanix.invidious = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 3001;
      backupDir = "/var/backup/invidious";
      hmacKeySecret = "invidious/hmac-key";
      companion.secretKeySecret = "invidious/companion-secret-key";

      expose = {
        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/invidious/secret-key-base64";
          hostname = "hdfigfl2dxihdtzkowytehos7k4fgcupgr2jy2yjr7erd5cupcl33lid.onion";
        };

        tailscale = {
          enable = true;
          port = 13001;
        };

        wireguard = {
          enable = true;
          port = 3001;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "5m";
        maxBackupAge = "15m";
      };

      users.buddia = {
        admin = true;
        passwordSecret = "invidious-passwords/buddia";
      };
    };

    alanix.immich = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 2283;
      backupDir = "/var/backup/immich";

      expose = {
        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/immich/secret-key-base64";
          hostname = "jvezpjvvukajiymxudgujcvlb3vne77zcj7juxhe7ejrdhqu35h6dead.onion";
        };

        tailscale = {
          enable = true;
          port = 12283;
        };

        wireguard = {
          enable = true;
          port = 2283;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "15m";
        maxBackupAge = "1h";
      };

      users.buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        name = "Alan Fife";
        passwordSecret = "immich-passwords/buddia";
      };
    };

    alanix.jellyfin = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8096;
      backupDir = "/var/backup/jellyfin";

      users.buddia = {
        admin = true;
        passwordSecret = "jellyfin-passwords/buddia";
      };

      libraries = {
        Movies = {
          type = "movies";
          folder = "movies";
        };

        Shows = {
          type = "tvshows";
          folder = "shows";
        };

        Recordings = {
          type = "homevideos";
          folder = "recordings";
        };
      };

      liveTv = {
        recordingPath = "/srv/tvheadend/recordings";

        tvheadend.sources.local = {
          enable = true;
          friendlyName = "alan-big-nixos TVHeadend";
          baseUrl = "http://alan-big-nixos:9981";
          playlistPath = "/playlist/channels";
          xmltvPath = "/xmltv/channels";
        };
      };

      expose = {
        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/jellyfin/secret-key-base64";
          hostname = "ca5amtznn5yqbiytylqaz3vplp6fm7s736gncdzjmezvkf2bhlm5ktad.onion";
        };

        tailscale = {
          enable = true;
          port = 18096;
        };

        wireguard = {
          enable = true;
          port = 8096;
        };
      };

      mediaFolders = {
        movies = {
          path = "/srv/media/movies";
          create = true;
          user = "buddia";
          group = "jellyfin";
          mode = "0775";
        };

        shows = {
          path = "/srv/media/shows";
          create = true;
          user = "buddia";
          group = "jellyfin";
          mode = "0775";
        };

        recordings = {
          path = "/srv/tvheadend/recordings";
          create = true;
          user = "root";
          group = "root";
          mode = "0755";
        };
      };

      cluster = {
        enable = true;
        backupInterval = "30m";
        maxBackupAge = "4h";
      };
    };

    alanix.nextcloud = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8080;
      backupDir = "/var/backup/nextcloud";
      rootUrl = "http://${config.alanix.tailscale.address}:8080";

      expose = {
        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/nextcloud/secret-key-base64";
          hostname = "ptptnhzb6idwmzj2lc6fnm4mzgvhzmkdmaut75n26ad6ej4ztytrhoid.onion";
        };

        tailscale = {
          enable = true;
          address = config.alanix.tailscale.address;
          port = 8080;
        };

        wireguard = {
          enable = true;
          port = 8080;
        };
      };

      collabora = {
        enable = true;
        rootUrl = "http://${config.alanix.tailscale.address}:9980";

        expose = {
          tor = {
            enable = true;
            publicPort = 9980;
            secretKeyBase64Secret = "tor/nextcloud-collabora/secret-key-base64";
            hostname = "5eputclnz26greh3rvjredwaoiqfjcjzvkx3r65i2lknsyw2br5o5jqd.onion";
          };

          tailscale = {
            enable = true;
            address = config.alanix.tailscale.address;
            port = 9980;
          };

          wireguard = {
            enable = true;
            port = 9980;
          };
        };
      };

      cluster = {
        enable = true;
        backupInterval = "15m";
        maxBackupAge = "1h";
      };

      users.buddia = {
        admin = true;
        displayName = "Alan Fife";
        email = "fife.alan@protonmail.com";
        passwordSecret = "nextcloud-passwords/buddia";
      };
    };

    alanix.searxng = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8888;
      secretKeySecret = "searxng-app/secret-key";
      settings.search.formats = [
        "html"
        "json"
      ];

      expose = {
        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/searxng/secret-key-base64";
          hostname = "kjhjydcizmjq7ufqsvcnqsqg2xxjaxq6l6khp5isehu7a766wv5m3jyd.onion";
        };

        tailscale = {
          enable = true;
          port = 18888;
        };

        wireguard = {
          enable = true;
          port = 8888;
        };
      };

      cluster = {
        enable = true;
      };
    };

    # alanix.openwebui = {
    #   enable = true;
    #   listenAddress = "127.0.0.1";
    #   port = 3002;
    #   backupDir = "/var/backup/openwebui";
    #   disableRegistration = true;
    #
    #   openai = {
    #     baseUrls = [ "http://alan-framework:4000/v1" ];
    #     apiKeys = [ "" ];
    #   };
    #
    #   webSearch = {
    #     enable = true;
    #     engine = "searxng";
    #     resultCount = 3;
    #     concurrentRequests = 1;
    #   };
    #
    #   expose = {
    #     tor = {
    #       enable = true;
    #       publicPort = 80;
    #       secretKeyBase64Secret = "tor/openwebui/secret-key-base64";
    #     };
    #
    #     wireguard = {
    #       enable = true;
    #       port = 3002;
    #     };
    #
    #     tailscale = {
    #       enable = true;
    #       port = 13002;
    #     };
    #   };
    #
    #   cluster = {
    #     enable = true;
    #     backupInterval = "5m";
    #     maxBackupAge = "15m";
    #   };
    #
    #   users.buddia = {
    #     admin = true;
    #     email = "fife.alan@protonmail.com";
    #     name = "Alan Fife";
    #     passwordSecret = "openwebui-passwords/buddia";
    #   };
    # };
  };
}
