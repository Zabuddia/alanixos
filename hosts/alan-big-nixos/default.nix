{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
      ../../clusters/home.nix
      ../../modules/services/bitcoin.nix
    ];

    alanix.system = {
      stateVersion = "25.11";
      timeZone = "America/Denver";
      locale = "en_US.UTF-8";
      enableSystemdBoot = true;
      canTouchEfiVariables = true;
      allowUnfree = true;
      experimentalFeatures = [ "nix-command" "flakes" ];
      enableNixLd = true;
      enableNetworkManager = true;
      enableFirewall = true;
      packages = with pkgs; [
        age
        caddy
        curl
        git
        htop
        jq
        python3
        restic
        sops
        tree
        unzip
        p7zip
        wget
      ];
      swapDevices = [
        {
          device = "/swapfile";
          size = 8192;
        }
      ];
    };

    alanix.users = {
      mutableUsers = false;
      accounts.buddia = {
        enable = true;
        isNormalUser = true;
        extraGroups = [ "wheel" "networkmanager" "input" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAJK6Bk63YjxmL9CI3F5yCjhG3MPAuuplydZ5ZmPFzW fife.alan@protonmail.com";
        authorizedHosts = [ "alan-framework" "alan-framework-laptop" "alan-laptop-nixos" "alan-node" "alan-optiplex" "randy-big-nixos" ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = { };
          packages = [ ];
          unstablePackages = with pkgs-unstable; [ yt-dlp ];
          modules = [ ];
        };

        git = {
          enable = true;
          github.user = "zabuddia";
          user.name = "Alan Fife";
          user.email = "fife.alan@protonmail.com";
          init.defaultBranch = "main";
          extraSettings = { };
        };

        sh.enable = true;

        azahar.enable = true;
        desktop.enable = true;
        chromium.enable = true;
        dolphin.enable = true;
        melonds.enable = true;
        ryubing.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      autoLogin = {
        enable = true;
        user = "buddia";
      };
      createHeadlessOutput = true;
      swayOutputRules = [
        "output HEADLESS-1 resolution 1920x1080"
      ];
      idle = {
        lockSeconds = null;
        displayOffSeconds = null;
        suspendSeconds = null;
      };
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnWireguard = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEOwubCYI6sBZbrhRLFMuV8IpReT40dcZ6qLBarejXxS";
    };

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
      listenPort = 51820;
      peers = [
        "randy-big-nixos"
        "alan-framework"
        "alan-framework-laptop"
        "alan-laptop-nixos"
        "alan-node"
        "alan-optiplex"
      ];
    };

    alanix.tailscale = {
      enable = true;
      address = "alan-big-nixos";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      deviceId = "5CVWFSK-CV4SWJP-Z7S4TTV-UAX263E-AEEWI6K-Z22GRUZ-F2JFFQY-LOZWLAS";
      listenPort = 22000;
      peers = [
        "alan-framework"
        "alan-framework-laptop"
      ];
      folderSets = [ "emulation" ];
      linkFolderSets = [ "emulation" ];
    };

    alanix.filebrowser = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8088;
      root = "/srv/filebrowser";
      database = "/var/lib/filebrowser/filebrowser.db";
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/filebrowser/secret-key-base64";
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 8088;
      };
      users = {
        admin = {
          admin = true;
          scope = ".";
          password = null;
          passwordFile = null;
          passwordSecret = "filebrowser-passwords/admin";
        };

        buddia = {
          admin = false;
          scope = "users/buddia";
          password = null;
          passwordFile = null;
          passwordSecret = "filebrowser-passwords/buddia";
        };
      };
    };

    alanix.openwebui = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 3002;
      disableRegistration = true;
      openai = {
        baseUrls = [ "http://alan-framework:4000/v1" ];
        apiKeys = [ "" ];
      };
      webSearch = {
        enable = true;
        engine = "searxng";
        resultCount = 3;
        concurrentRequests = 1;
      };
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/openwebui/secret-key-base64";
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 3002;
      };
      expose.tailscale = {
        enable = true;
        port = 13002;
      };
      users.buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        name = "Alan Fife";
        passwordSecret = "openwebui-passwords/buddia";
      };
    };

    alanix.searxng = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8888;
      settings.search.formats = [
        "html"
        "json"
      ];
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/searxng/secret-key-base64";
      };
      expose.tailscale = {
        enable = true;
        port = 18888;
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 8888;
      };
    };

    alanix.jellyfin = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8096;
      users = {
        buddia = {
          admin = true;
          passwordSecret = "jellyfin-passwords/buddia";
        };
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
      liveTv.tvheadend.sources.local = {
        enable = true;
        friendlyName = "Local TVHeadend";
        baseUrl = "http://127.0.0.1:9981";
        playlistPath = "/playlist/channels";
        xmltvPath = "/xmltv/channels";
      };
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/jellyfin/secret-key-base64";
      };
      expose.tailscale = {
        enable = true;
        port = 18096;
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 8096;
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
        };
      };
    };

    alanix.immich = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 2283;
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/immich/secret-key-base64";
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 2283;
      };
      users.buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        name = "Alan Fife";
        passwordSecret = "immich-passwords/buddia";
      };
    };

    alanix.nextcloud = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 8080;
      rootUrl = "http://alan-big-nixos:8080";
      trustedDomains = [ "alan-big-nixos" ];
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/nextcloud/secret-key-base64";
      };
      expose.tailscale = {
        enable = true;
        address = "100.97.81.46";
        port = 8080;
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 8080;
      };
      users.buddia = {
        admin = true;
        displayName = "Alan Fife";
        email = "fife.alan@protonmail.com";
        passwordSecret = "nextcloud-passwords/buddia";
      };
      collabora = {
        enable = true;
        rootUrl = "http://alan-big-nixos:9980";
        expose.tor = {
          enable = true;
          publicPort = 9980;
          secretKeyBase64Secret = "tor/nextcloud-collabora/secret-key-base64";
        };
        expose.tailscale = {
          enable = true;
          address = "100.97.81.46";
          port = 9980;
        };
        expose.wireguard = {
          enable = true;
          address = "10.100.0.1";
          port = 9980;
        };
      };
    };

    alanix.tvheadend = {
      enable = true;
      recordingsDir = "/srv/tvheadend/recordings";
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/tvheadend/secret-key-base64";
      };
      expose.tailscale = {
        enable = true;
        port = 19981;
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 9981;
      };
      htsp.expose.tailscale = {
        enable = true;
        port = 19982;
      };
      htsp.expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 9982;
      };
    };

    alanix.remote-desktop = {
      enable = true;
      autoStart = true;
      port = 5900;
      output = "HEADLESS-1";
    };

    alanix.sunshine = {
      enable = true;
      autoStart = true;
      openFirewall = true;
      capSysAdmin = true;
      webUi = {
        port = 47990;
        username = "buddia";
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-big-nixos".path;
      };
    };
  };
}
