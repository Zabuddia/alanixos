{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
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
        restic
        sops
        tree
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
        extraGroups = [ "wheel" "networkmanager" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = {
            ".ssh/id_ed25519.pub" = {
              text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAJK6Bk63YjxmL9CI3F5yCjhG3MPAuuplydZ5ZmPFzW fife.alan@protonmail.com";
              source = null;
              force = true;
              executable = null;
            };
          };
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

        ssh = {
          enable = false;
          matchBlocks = { };
        };

        desktop.enable = false;
        chromium.enable = true;
        librewolf.enable = false;
        nextcloudClient.enable = false;
        trayscale.enable = false;
        vscode.enable = false;
      };
    };

    alanix.desktop = {
      enable = true;
      autoLogin = {
        enable = false;
        user = null;
      };
      createHeadlessOutput = false;
      swayOutputRules = [ ];
      idle = {
        lockSeconds = null;
        displayOffSeconds = null;
        suspendSeconds = null;
      };
    };

    alanix.power = {
      enable = false;
      enablePowerProfilesDaemon = true;
      enableUpower = true;
      enableThermald = true;
      enablePowertop = true;
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnWireguard = true;
      startAgent = true;
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
        "alan-laptop-nixos"
      ];
    };

    alanix.tailscale = {
      enable = true;
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.bitcoin = {
      enable = true;
      configVersion = "0.0.85";
      generateSecrets = true;
      operatorName = "operator";
      useDoas = true;
      hideProcessInformation = true;
      exposeSshOnionService = true;
      copyRootSshKeysToOperator = true;
      enableNodeInfo = true;
      backupsFrequency = "daily";

      bitcoind = {
        listen = true;
        dbCache = 1000;
        txindex = true;
      };

      fulcrum.enable = true;

      mempool = {
        enable = true;
        electrumServer = "fulcrum";
        frontend = {
          address = "0.0.0.0";
          port = 4080;
        };
      };
    };

    alanix.filebrowser = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 8088;
      root = "/srv/filebrowser";
      database = "/var/lib/filebrowser/filebrowser.db";
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

    alanix.llm = {
      enable = false;
      backend = "cpu";
      stateDir = "/var/lib/llm";
      instances = { };
    };

    alanix.openclaw = {
      enable = false;
      bind = "loopback";
      customBindHost = null;
      port = 18789;
      tokenSecret = null;
      primaryLlmInstance = null;
      imageLlmInstance = null;
      embeddingLlmInstance = null;
      enableResponsesApi = true;
      enableChatCompletionsApi = true;
      enableTailscaleServe = false;

      controlUi = {
        allowedOrigins = [ ];
        dangerouslyDisableDeviceAuth = false;
      };

      telegram = {
        enable = false;
        tokenSecret = null;
        allowFrom = [ ];
        dmPolicy = null;
        groupPolicy = null;
        configWrites = false;
      };

      webSearch = {
        enable = false;
        apiKeySecret = null;
        braveMode = "web";
      };

      browser = {
        enable = false;
        evaluateEnabled = false;
        headless = true;
        package = null;
        executablePath = null;
      };

      canvas = {
        enable = false;
        nodePackage = null;
      };

      desktopNode = {
        enable = false;
        user = null;
        displayName = null;
        gatewayHost = null;
      };

      extraConfig = { };
    };

    alanix.remote-desktop = {
      enable = false;
      autoStart = true;
      port = 5900;
      output = null;
    };

    alanix.sunshine = {
      enable = false;
      autoStart = true;
      openFirewall = false;
      capSysAdmin = false;
      webUi = {
        port = 47990;
        username = null;
        passwordFile = null;
      };
    };
  };
}
