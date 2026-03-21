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
              text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKpHeGMaMDqWna8I5fu0K2kaZ1GdOFIGw+8NsgH3aXE3 fife.alan@protonmail.com";
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
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnWireguard = true;
      startAgent = true;
    };

    alanix.ddns = {
      enable = true;
      provider = "cloudflare";
      domains = [ "randy-big-nixos-wg.fifefin.com" ];
      credentialsFile = config.sops.templates."cloudflare-env".path;
    };

    alanix.wireguard = {
      enable = true;
      vpnIP = "10.100.0.2";
      endpoint = "randy-big-nixos-wg.fifefin.com:51820";
      publicKey = "YD/m4D7uTGFnWBEACTkc7MnY7yG0yvRVAEJKqOQ91UE=";
      privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
      listenPort = 51820;
      peers = [
        "alan-big-nixos"
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
      enable = false;
      configVersion = null;
      generateSecrets = false;
      operatorName = null;
      useDoas = false;
      hideProcessInformation = false;
      exposeSshOnionService = false;
      copyRootSshKeysToOperator = false;
      enableNodeInfo = false;
      backupsFrequency = null;

      bitcoind = {
        listen = null;
        dbCache = null;
        txindex = null;
      };

      fulcrum.enable = false;

      mempool = {
        enable = false;
        electrumServer = null;
        frontend = {
          address = null;
          port = null;
        };
      };
    };

    alanix.filebrowser = {
      enable = false;
      listenAddress = null;
      port = null;
      root = null;
      database = null;
      users = { };
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
      port = 5900;
      user = null;
    };

    alanix.sunshine = {
      enable = false;
      autoStart = true;
      capSysAdmin = false;
    };
  };
}
