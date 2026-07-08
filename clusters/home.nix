{ config, lib, hostname, pkgs, ... }:
let
  members = [
    "alan-big-nixos"
    "randy-big-nixos"
    "alan-node"
  ];

  mailDkimTxt = lib.concatStrings [
    "v=DKIM1; k=rsa; p="
    "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnKr7G7M2LwNDdniDSDjXRk5L/6mX/egNq4m1lPVK1BgrHhJYn5XPsJQ6XXlKVUWiUlLBR6Fe8OgS9QxlEAhJzNEyaRpMMbAV/OK/Eb1LNN3hQMp47LNKP0kfCDBUJUANYg1I02hFjQt8LDBFZ2u5vt66bs0Sio1LEz+iMyUHSqJfaHqz8hJiuPJgEb7JZBxI0Uq6xpaOyNd7lhR7heSukrMj5f9iK7mah3NMo9QcjwpZObX7YRbU7XBcu/sffe58PmVBa4BplzmpM2x9m4J8Zyb8BNsZgy+S0gidYtTxmpQ2KMG/7qlP8ZLIxKtEf8PnOMeESiYJr5ZAbwsBUI6kbQIDAQAB"
  ];

  isMember = builtins.elem hostname members;
in
{
  config = lib.mkIf isMember {
    security.acme.defaults.email = "fife.alan@protonmail.com";

    sops.templates."cloudflare-env-cluster" = {
      content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
      owner = "root";
    };

    sops.templates."cloudflare-acme-cluster" = {
      content = "CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder."cloudflare/api-token"}";
      owner = "root";
    };

    alanix.cluster = {
      enable = true;
      name = "home";
      transport = "tailscale";
      members = members;
      voters = members;
      priority = members;
      addresses = {
        randy-big-nixos = "randy-big-nixos";
        alan-big-nixos = "alan-big-nixos";
        alan-node = "alan-node";
      };

      etcd = {
        bootstrapGeneration = 3;
        heartbeatInterval = "500ms";
        electionTimeout = "5s";
        leaseTtl = "3m";
        renewEvery = "5s";
        acquisitionStep = "5s";
        dialTimeout = "5s";
        commandTimeout = "15s";
      };

      backup = {
        repoUser = "buddia";
        repoBaseDir = "/var/lib/alanix-backups";
        passwordSecret = "cluster/restic-password";
        retainDays = 30;
      };

      dashboard = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9842;
        recentEvents = 40;
        admin.passwordFile = config.sops.secrets."cluster/dashboard-password".path;

        expose = {
          wan = {
            enable = true;
            domain = "dashboard.fifefin.com";
          };

          tailscale = {
            enable = true;
            port = 19842;
          };

          tor = {
            enable = true;
            publicPort = 80;
            secretKeyBase64Secret = "tor/cluster-dashboard/${hostname}/secret-key-base64";
            hostname =
              if hostname == "alan-big-nixos" then "uu6th6s6ry55vqdp7dbt6znbyedvgeqlmat2venoxkyijq5qk3lipiad.onion"
              else if hostname == "alan-node" then "u7pemgmtbljkrsc2dyqivx7u4kpy76ajf7hmsnlubmhs33uo4tw5txid.onion"
              else if hostname == "randy-big-nixos" then "wzzhb5g6vfmk76k2a7ccfh4r53qjxsprneizy2ikhplhz3flluacqxqd.onion"
              else null;
          };
        };
      };

      ddns = {
        enable = true;
        credentialsFile = config.sops.templates."cloudflare-env-cluster".path;
        ipv4Provider = "cloudflare.trace";
        ipv6Provider = "none";
        detectionTimeout = "15s";
        domains = [
          "headscale.fifefin.com"
          "headplane.fifefin.com"
          "dashboard.fifefin.com"
          "filebrowser.fifefin.com"
          "forgejo.fifefin.com"
          "grocy.fifefin.com"
          "homebox.fifefin.com"
          "nextcloud.fifefin.com"
          "collabora.fifefin.com"
          "immich.fifefin.com"
          "invidious.fifefin.com"
          "vaultwarden.fifefin.com"
          "jellyfin.fifefin.com"
          "jitsi.fifefin.com"
          "mail.fifefin.com"
          "mqtt.fifefin.com"
          "navidrome.fifefin.com"
          "audiobookshelf.fifefin.com"
          "kavita.fifefin.com"
          "owntracks.fifefin.com"
          "radicale.fifefin.com"
          "searxng.fifefin.com"
          "roundcube.fifefin.com"
          "openwebui.fifefin.com"
          "actual.fifefin.com"
        ];
      };
    };

    alanix.cloudflare.dns = {
      enable = true;
      credentialsFile = config.sops.templates."cloudflare-env-cluster".path;
      cluster.enable = true;

      zones."fifefin.com".records = [
        {
          name = "@";
          type = "MX";
          content = "mail.fifefin.com";
          priority = 10;
          comment = "primary mail exchanger";
        }
        {
          name = "@";
          type = "TXT";
          content = "v=spf1 mx -all";
          comment = "SPF for fifefin.com mail";
        }
        {
          name = "_dmarc";
          type = "TXT";
          content = "v=DMARC1; p=none; rua=mailto:postmaster@fifefin.com";
          comment = "DMARC aggregate reports";
        }
        {
          name = "mail._domainkey";
          type = "TXT";
          content = mailDkimTxt;
          comment = "DKIM public key for simple-nixos-mailserver";
        }
      ];
    };

    alanix.users.accounts.buddia.extraGroups = [ "filebrowser" ];
    users.users.filebrowser.extraGroups = [ "users" ];

    alanix.adguardhome = {
      enable = true;
      mutableSettings = false;
      filtersUpdateInterval = 6;

      cluster = {
        enable = true;
        resolverHosts = [
          "alan-big-nixos"
          "alan-node"
          "randy-big-nixos"
        ];
        resolverAddresses = {
          alan-big-nixos = "100.64.0.3";
          alan-node = "100.64.0.5";
          randy-big-nixos = "100.64.0.6";
        };
        lanBindHosts.alan-big-nixos = [ "192.168.10.225" ];
      };

      web = {
        listenAddress = "127.0.0.1";
        port = 3002;
      };

      dns = {
        port = 53;
        upstreamDns = [ "127.0.0.1" ];
        bootstrapDns = [ ];
      };

      filters = [
        {
          enabled = true;
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt";
          name = "HaGeZi Multi PRO";
          id = 1;
        }
        {
          enabled = true;
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt";
          name = "HaGeZi Threat Intelligence Feeds";
          id = 2;
        }
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
          name = "AdGuard DNS filter";
          id = 3;
        }
        {
          enabled = true;
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/dyndns.txt";
          name = "HaGeZi Dynamic DNS";
          id = 4;
        }
        {
          enabled = true;
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/nsfw.txt";
          name = "HaGeZi NSFW";
          id = 5;
        }
        {
          enabled = true;
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/gambling.txt";
          name = "HaGeZi Gambling";
          id = 6;
        }
        {
          enabled = true;
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/anti.piracy.txt";
          name = "HaGeZi Anti-Piracy";
          id = 7;
        }
        {
          enabled = true;
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/nosafesearch.txt";
          name = "HaGeZi No SafeSearch";
          id = 8;
        }
      ];

      settings.filtering = {
        blocked_services = {
          ids = [ "tiktok" ];
          schedule.time_zone = "Local";
        };

        safe_search = {
          enabled = true;
          bing = true;
          duckduckgo = true;
          ecosia = true;
          google = true;
          pixabay = true;
          yandex = true;
          youtube = true;
        };
      };

      expose.tailscale = {
        enable = true;
        port = 13002;
      };
    };

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      listenPort = 22000;
      # File Browser relies on group-writable synced directories so the
      # filebrowser service can create files inside newly received folders.
      umask = "0002";
      syncRoot = "/srv/syncthing";
      folderSets = [ "movies" "shows" "videos" "music" "audiobooks" "ebooks" "filebrowser-files" ];
      externalDevices.pixel-fold = {
        id = "BT23SPJ-ICTEBQ7-GJTDRQT-LCUQ773-U63QFZR-472O3YA-2KRJ4KY-AMPZ7AF";
        addresses = [ "tcp://pixel-fold:22000" ];
        folderSets = [ "videos" "ebooks" "filebrowser-buddia-files" ];
      };
    };

    alanix.headscale = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8086;
      serverUrl = "https://headscale.fifefin.com";
      baseDomain = "tail.fifefin.com";
      backupDir = "/var/backup/headscale";
      routeAutoApprovers = {
        "192.168.10.0/24" = [ "fife.alan@protonmail.com" ];
      };

      dns = {
        overrideLocalDns = true;
      };

      derp = {
        enable = true;
        stunPort = 3478;
        useUpstreamDerpMap = true;
      };

      expose.wan = {
        enable = true;
        domain = "headscale.fifefin.com";
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.unbound = {
      enable = true;
      settings.server.private-address = [
        "10.0.0.0/8"
        "169.254.0.0/16"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "fc00::/7"
        "fe80::/10"
      ];
    };

    alanix.headplane = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8087;
      baseUrl = "https://headplane.fifefin.com";
      backupDir = "/var/backup/headplane";

      expose = {
        wan = {
          enable = true;
          domain = "headplane.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/headplane/secret-key-base64";
          hostname = "2tf3kobh4qab3uieuquw6ose2vs4qvrzcu2edvrkkpsjm4dnnvm4wpad.onion";
        };

        tailscale = {
          enable = true;
          port = 18087;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
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
        wan = {
          enable = true;
          domain = "vaultwarden.fifefin.com";
        };

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
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
        sameTorAddress = true;
      };
    };

    alanix.actual = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 5006;
      backupDir = "/var/backup/actual";
      passwordSecret = "actual-passwords/server-password";

      expose = {
        wan = {
          enable = true;
          domain = "actual.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 443;
          tls = true;
          secretKeyBase64Secret = "tor/actual/secret-key-base64";
          hostname = "b2yp726tcvvlfbcmcfgnckor2ws6df3oem2brsd2yovlbmsdwnq3gsyd.onion";
          tlsName = "b2yp726tcvvlfbcmcfgnckor2ws6df3oem2brsd2yovlbmsdwnq3gsyd.onion";
        };

        tailscale = {
          enable = true;
          port = 15006;
          tls = true;
          tlsName = config.alanix.tailscale.address;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.forgejo = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 3000;
      rootUrl = "https://forgejo.fifefin.com";
      backupDir = "/var/backup/forgejo";

      expose = {
        wan = {
          enable = true;
          domain = "forgejo.fifefin.com";
        };

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
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
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
      root = "${config.alanix.syncthing.syncRoot}/filebrowser";
      rootUser = "buddia";
      rootGroup = "users";
      rootMode = "2775";
      database = "/var/lib/filebrowser/filebrowser.db";
      backupDir = "/var/backup/filebrowser";

      expose = {
        wan = {
          enable = true;
          domain = "filebrowser.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/filebrowser/secret-key-base64";
          hostname = "aopakfwm2dgsp7uawi64jkqpmctptlgj2aokov5nb6lgwfv33ru26xqd.onion";
        };

        tailscale = {
          enable = true;
          address = config.alanix.tailscale.address;
          port = 8088;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
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

    alanix.grocy = {
      enable = true;
      hostName = "grocy.fifefin.com";
      listenAddress = "127.0.0.1";
      port = 8091;
      backupDir = "/var/backup/grocy";

      users.buddia = {
        passwordSecret = "grocy-passwords/buddia";
        admin = true;
      };

      expose = {
        wan = {
          enable = true;
          domain = "grocy.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/grocy/secret-key-base64";
          hostname = "x3azimkrpa7x36q4kpa5modub3iemb5h6rcl7uw5x7cvogthb2limjyd.onion";
        };

        tailscale = {
          enable = true;
          port = 18091;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.homebox = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8092;
      backupDir = "/var/backup/homebox";
      allowRegistration = true;

      users.buddia = {
        name = "Alan Fife";
        email = "fife.alan@protonmail.com";
        passwordSecret = "homebox-passwords/buddia";
      };

      expose = {
        wan = {
          enable = true;
          domain = "homebox.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/homebox/secret-key-base64";
          hostname = "h5tuqb4maq5nv4xegivo6zcnm3fpxbjawdydsqu4xsisswhukivweoyd.onion";
        };

        tailscale = {
          enable = true;
          port = 18092;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.radicale = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 5232;
      storageDir = "/var/lib/radicale/collections";
      backupDir = "/var/backup/radicale";

      expose = {
        wan = {
          enable = true;
          domain = "radicale.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/radicale/secret-key-base64";
          hostname = "kyc2dv6gfdf7nkcyprdhxu2wv3wmjka3rzkoknglvsc7ezhuqhl4c6id.onion";
        };

        tailscale = {
          enable = true;
          port = 15232;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };

      users.buddia.passwordSecret = "radicale-passwords/buddia";
    };

    alanix.mail = {
      enable = true;
      domain = "fifefin.com";
      fqdn = "mail.fifefin.com";
      sendingFqdn = "mail.fifefin.com";
      systemContact = "postmaster@fifefin.com";
      certificateScheme = "acme";
      localDnsResolver = false;

      acme = {
        dnsProvider = "cloudflare";
        credentialsFile = config.sops.templates."cloudflare-acme-cluster".path;
      };

      accounts.buddia = {
        passwordHashSecret = "mail-password-hashes/buddia";
        aliases = [
          "abuse@fifefin.com"
          "admin@fifefin.com"
          "alan@fifefin.com"
          "fife.alan@fifefin.com"
          "postmaster@fifefin.com"
        ];
      };

      dkim = {
        privateKeySecrets."fifefin.com" = "mail-dkim/fifefin.com/mail-private-key";
        publicTxtRecords."fifefin.com" = mailDkimTxt;
      };

      cluster = {
        enable = true;
        backupDir = "/var/backup/mail";
        backupInterval = "12h";
      };
    };

    alanix.roundcube = {
      enable = true;
      hostName = "roundcube.fifefin.com";
      listenAddress = "127.0.0.1";
      port = 8090;
      productName = "Alanix RoundCube";
      backupDir = "/var/backup/roundcube";

      mail = {
        domain = "fifefin.com";
        imapHost = "ssl://mail.fifefin.com:993";
        smtpHost = "ssl://mail.fifefin.com:465";
      };

      expose = {
        wan = {
          enable = true;
          domain = "roundcube.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/roundcube/secret-key-base64";
          hostname = "ch6ybzasm6hhz34k67vajez5qiin5cqsxbyxvfsnndiddspifxncyayd.onion";
        };

        tailscale = {
          enable = true;
          port = 18090;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.owntracks = {
      enable = true;
      backupDir = "/var/backup/owntracks";

      mqtt = {
        domain = "mqtt.fifefin.com";
        publicPort = 8883;
        acme = {
          dnsProvider = "cloudflare";
          credentialsFile = config.sops.templates."cloudflare-acme-cluster".path;
        };
      };

      recorder = {
        listenAddress = "127.0.0.1";
        port = 8083;
        stateDir = "/var/lib/owntracks-recorder";

        expose = {
          wan = {
            enable = true;
            domain = "owntracks.fifefin.com";
          };

          tailscale = {
            enable = true;
            port = 18083;
          };

          tor = {
            enable = true;
            publicPort = 443;
            tls = true;
            tlsName = "ebap4jphsru2cfno3n3gjl6btx6p4ik77gmnj63vrnwd2z7uga4ccfqd.onion";
            secretKeyBase64Secret = "tor/owntracks/secret-key-base64";
            hostname = "ebap4jphsru2cfno3n3gjl6btx6p4ik77gmnj63vrnwd2z7uga4ccfqd.onion";
          };
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };

      users.buddia = {
        passwordSecret = "owntracks-passwords/buddia";
        recorderViewer = true;
      };
    };

    alanix.invidious = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 3001;
      backupDir = "/var/backup/invidious";
      hmacKeySecret = "invidious/hmac-key";
      companion = {
        publicUrl = "https://invidious.fifefin.com/companion";
        secretKeySecret = "invidious/companion-secret-key";
      };

      expose = {
        wan = {
          enable = true;
          domain = "invidious.fifefin.com";
        };

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
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
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
        wan = {
          enable = true;
          domain = "immich.fifefin.com";
        };

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
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
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
      extraGroups = [ "users" ];

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

        Videos = {
          type = "homevideos";
          folder = "videos";
        };
      };

      liveTv = {
        recordingPath = "/srv/jellyfin/recordings";

        hdhomerun.sources.local = {
          enable = true;
          friendlyName = "HDHomeRun";
          url = "192.168.10.105";
        };
      };

      expose = {
        wan = {
          enable = true;
          domain = "jellyfin.fifefin.com";
        };

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
      };

      mediaFolders = {
        movies = {
          path = "${config.alanix.syncthing.syncRoot}/media/movies";
          create = true;
          user = "buddia";
          group = "users";
          mode = "2775";
        };

        shows = {
          path = "${config.alanix.syncthing.syncRoot}/media/shows";
          create = true;
          user = "buddia";
          group = "users";
          mode = "2775";
        };

        recordings = {
          path = "/srv/jellyfin/recordings";
          create = true;
          user = "jellyfin";
          group = "jellyfin";
          mode = "0755";
        };

        videos = {
          path = "${config.alanix.syncthing.syncRoot}/media/videos";
          create = true;
          user = "buddia";
          group = "users";
          mode = "2775";
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.jitsi-meet = {
      enable = true;
      hostName = "jitsi.fifefin.com";
      listenAddress = "127.0.0.1";
      port = 8095;
      backupDir = "/var/backup/jitsi-meet";

      jicofo.restPort = 8889;
      videobridge = {
        privateHttpPort = 9091;
        allowedAddresses = lib.optionals (hostname == "alan-big-nixos") [ "192.168.10.225" ];
      };

      turn = {
        enable = true;
        # Headscale's embedded DERP server already uses UDP 3478 for STUN.
        port = 3479;
      };

      expose.wan = {
        enable = true;
        domain = "jitsi.fifefin.com";
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.audiobookshelf = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 13378;
      backupDir = "/var/backup/audiobookshelf";
      extraGroups = [ "users" ];

      users.buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        passwordSecret = "audiobookshelf-passwords/buddia";
      };

      libraries.Audiobooks = {
        mediaType = "book";
        folders = [ "${config.alanix.syncthing.syncRoot}/media/audiobooks" ];
      };

      mediaFolders.books = {
        path = "${config.alanix.syncthing.syncRoot}/media/audiobooks";
        create = true;
        user = "buddia";
        group = "users";
        mode = "2775";
      };

      expose = {
        wan = {
          enable = true;
          domain = "audiobookshelf.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/audiobookshelf/secret-key-base64";
          hostname = "yhoyukchgqwdehu5t4s2vaj6feozpw353ykv47ki2eeq7bilvazctaad.onion";
        };

        tailscale = {
          enable = true;
          address = config.alanix.tailscale.address;
          port = 13378;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.kavita = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 5000;
      backupDir = "/var/backup/kavita";
      extraGroups = [ "users" ];

      users.buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        passwordSecret = "kavita-passwords/buddia";
      };

      libraries.Ebooks = {
        type = "Book";
        folders = [ "${config.alanix.syncthing.syncRoot}/media/ebooks" ];
      };

      mediaFolders.ebooks = {
        path = "${config.alanix.syncthing.syncRoot}/media/ebooks";
        create = true;
        user = "buddia";
        group = "users";
        mode = "2775";
      };

      expose = {
        wan = {
          enable = true;
          domain = "kavita.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/kavita/secret-key-base64";
          hostname = "fmandr4ystw6pod5kz3obrczjz2pztqf2l627hmpfc2bwn26kh673zqd.onion";
        };

        tailscale = {
          enable = true;
          address = config.alanix.tailscale.address;
          port = 5000;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.navidrome = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 4533;
      scanInterval = "5m";
      purgeMissing = "always";
      backupDir = "/var/backup/navidrome";
      extraGroups = [ "users" ];
      users.buddia = {
        admin = true;
        passwordSecret = "navidrome-passwords/buddia";
      };

      internetRadioStations.alanix_sdr = {
        name = "Alanix SDR Radio";
        streamUrl = "http://alan-big-nixos:18075/live.mp3";
      };

      mediaFolders.music = {
        path = "${config.alanix.syncthing.syncRoot}/media/music";
        create = true;
        user = "buddia";
        group = "users";
        mode = "2775";
      };

      expose = {
        wan = {
          enable = true;
          domain = "navidrome.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/navidrome/secret-key-base64";
          hostname = "kzqxdpzahx7rxsok4hvwquwekmek2jdzw57n5xn6yzbpbbbs6k4d2oqd.onion";
        };

        tailscale = {
          enable = true;
          port = 14533;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };

    alanix.nextcloud = {
      enable = true;
      package = pkgs.nextcloud33;
      listenAddress = "127.0.0.1";
      port = 8080;
      backupDir = "/var/backup/nextcloud";
      rootUrl = "https://nextcloud.fifefin.com";

      expose = {
        wan = {
          enable = true;
          domain = "nextcloud.fifefin.com";
        };

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
      };

      collabora = {
        enable = true;
        rootUrl = "https://collabora.fifefin.com";

        expose = {
          wan = {
            enable = true;
            domain = "collabora.fifefin.com";
          };

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
        };
      };

      appIds = [
        "contacts"
        "calendar"
        "tasks"
        "notes"
        "deck"
        "forms"
        "richdocuments"
        "polls"
        "mail"
      ];

      cluster = {
        enable = true;
        backupInterval = "12h";
      };

      users = {
        fifefam = {
          admin = false;
          displayName = "Fife Family";
          email = "fifefam@gmail.com";
          passwordSecret = "nextcloud-passwords/fifefam";
        };
        waffleiron = {
          admin = false;
          displayName = "Randy Fife";
          email = "fife.randy@protonmail.com";
          passwordSecret = "nextcloud-passwords/waffleiron";
        };
        buddia = {
          admin = true;
          displayName = "Alan Fife";
          email = "fife.alan@protonmail.com";
          passwordSecret = "nextcloud-passwords/buddia";
        };
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
        wan = {
          enable = true;
          domain = "searxng.fifefin.com";
        };

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
      };

      cluster = {
        enable = true;
      };
    };

    alanix.openwebui = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 18080;
      rootUrl = "https://openwebui.fifefin.com";
      disableRegistration = true;
      backupDir = "/var/backup/openwebui";

      openai = {
        baseUrls = [ "http://alan-framework:4000/v1" ];
        apiKeys = [ "none" ];
      };

      webSearch = {
        enable = true;
        engine = "searxng";
        searxngQueryUrl = "http://127.0.0.1:8888/search?q=<query>&format=json";
      };

      users.buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        name = "Alan Fife";
        passwordSecret = "openwebui-passwords/buddia";
      };

      expose = {
        wan = {
          enable = true;
          domain = "openwebui.fifefin.com";
        };

        tor = {
          enable = true;
          publicPort = 80;
          secretKeyBase64Secret = "tor/openwebui/secret-key-base64";
          hostname = "uogrbydngyykybpe7eo4w6mxllcnany6dgkbskfjkzncg6upe4mwedqd.onion";
        };

        tailscale = {
          enable = true;
          port = 18000;
        };
      };

      cluster = {
        enable = true;
        backupInterval = "12h";
      };
    };
  };
}
