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
        vlc
        ffmpeg
        w_scan2
        nano
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

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = {
            ".ssh/id_ed25519.pub" = {
              text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNJ7KX0IIt27KqD2c3dqMT8vbO0K/G1ibfC+a/WxijO fife.alan@protonmail.com";
              source = null;
              force = true;
              executable = null;
            };

            ".ssh/id_ed25519_work.pub" = {
              text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZHjKqhqWZalx6/NsQv1OGXJP6LBMfXS0QedqwhjFzl briggsconsulting.coaching@gmail.com";
              source = null;
              force = true;
              executable = null;
            };
          };
          packages = with pkgs; [
            xournalpp
            libreoffice
            remmina
            tor-browser
          ];
          unstablePackages = with pkgs-unstable; [
            yt-dlp
            gimp
            firefox
            moonlight-qt
          ];
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
          enable = true;
          matchBlocks = {
            "github-personal" = {
              hostname = "github.com";
              user = "git";
              identityFile = "~/.ssh/id_ed25519";
              identitiesOnly = true;
              controlPath = "none";
            };

            "github-work" = {
              hostname = "github.com";
              user = "git";
              identityFile = "~/.ssh/id_ed25519_work";
              identitiesOnly = true;
              controlPath = "none";
            };
          };
        };

        desktop.enable = true;
        chromium.enable = true;
        librewolf.enable = true;
        nextcloudClient.enable = true;
        trayscale.enable = true;
        vscode.enable = true;
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
        lockSeconds = 300;
        displayOffSeconds = 330;
        suspendSeconds = 1800;
      };
    };

    alanix.power = {
      enable = true;
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
      domains = [ "alan-laptop-nixos-wg.fifefin.com" ];
      credentialsFile = config.sops.templates."cloudflare-env".path;
    };

    alanix.wireguard = {
      enable = true;
      vpnIP = "10.100.0.4";
      endpoint = "alan-laptop-nixos-wg.fifefin.com:51820";
      publicKey = "U96LblYX6Klccf6yFVmKDQZp4882rSPTWq2wzFmbVV4=";
      privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
      listenPort = 51820;
      peers = [
        "alan-big-nixos"
        "randy-big-nixos"
        "alan-framework"
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
      enable = true;
      autoStart = false;
      port = 5900;
      output = null;
    };

    alanix.sunshine = {
      enable = true;
      autoStart = false;
      openFirewall = false;
      capSysAdmin = true;
      webUi = {
        port = 47990;
        username = "buddia";
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-laptop-nixos".path;
      };
    };
  };
}
