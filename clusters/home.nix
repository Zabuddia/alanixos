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
  };
}
