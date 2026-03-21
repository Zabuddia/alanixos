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
      swapDevices = [ ];
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
              text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILb22RXxaO/RmZkheVk+Ma9WBXABHN/IrDGq5RbBIunC fife.alan@protonmail.com";
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
      domains = [ "alan-framework-wg.fifefin.com" ];
      credentialsFile = config.sops.templates."cloudflare-env".path;
    };

    alanix.wireguard = {
      enable = true;
      vpnIP = "10.100.0.3";
      endpoint = "alan-framework-wg.fifefin.com:51820";
      publicKey = "f6MBPUIr8jLqr8F4LDvJksJIN/BvGnDGG8OycXbrd1c=";
      privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
      listenPort = 51820;
      peers = [
        "alan-big-nixos"
        "randy-big-nixos"
        "alan-laptop-nixos"
      ];
    };

    alanix.tailscale = {
      enable = true;
      acceptRoutes = true;
      operator = "openclaw";
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
      enable = true;
      backend = "vulkan";
      stateDir = "/var/lib/llm";
      instances = {
        chat = {
          enable = true;
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8080;
          alias = null;
          ctxSize = 262144;
          batchSize = 2048;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [ "text" ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3.5-35b-a3b";
            path = null;
            url = null;
            hfRepo = "unsloth/Qwen3.5-35B-A3B-GGUF";
            hfFile = "Qwen3.5-35B-A3B-UD-Q5_K_XL.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          extraArgs = [ ];
        };

        vision = {
          enable = true;
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8081;
          alias = null;
          ctxSize = 32768;
          batchSize = 2048;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [
            "text"
            "image"
          ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3-vl-30b-a3b-instruct";
            path = null;
            url = null;
            hfRepo = "unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF";
            hfFile = "Qwen3-VL-30B-A3B-Instruct-Q4_K_M.gguf";
            mmprojPath = null;
            mmprojUrl = "https://huggingface.co/unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF/resolve/main/mmproj-F16.gguf";
          };
          extraArgs = [ ];
        };

        embeddings = {
          enable = true;
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8082;
          alias = null;
          ctxSize = 8192;
          batchSize = 2048;
          ubatchSize = 512;
          parallel = 1;
          gpuLayers = "all";
          flashAttention = "on";
          threads = null;
          threadsBatch = null;
          mmap = true;
          mlock = false;
          input = [ "text" ];
          imageMinTokens = null;
          imageMaxTokens = null;
          model = {
            name = "qwen3-embedding-4b";
            path = null;
            url = null;
            hfRepo = "Qwen/Qwen3-Embedding-4B-GGUF";
            hfFile = "Qwen3-Embedding-4B-Q5_K_M.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          extraArgs = [ "--embeddings" ];
        };
      };
    };

    alanix.openclaw = {
      enable = true;
      bind = "loopback";
      customBindHost = null;
      port = 18789;
      tokenSecret = "openclaw/gateway-token";
      primaryLlmInstance = "chat";
      imageLlmInstance = "vision";
      embeddingLlmInstance = "embeddings";
      enableResponsesApi = true;
      enableChatCompletionsApi = true;
      enableTailscaleServe = true;

      controlUi = {
        allowedOrigins = [ "https://alan-framework.tailbb2802.ts.net" ];
        dangerouslyDisableDeviceAuth = true;
      };

      telegram = {
        enable = true;
        tokenSecret = "telegram/bot-token";
        allowFrom = [ 7336229793 5255330939 ];
        dmPolicy = "allowlist";
        groupPolicy = "disabled";
        configWrites = false;
      };

      webSearch = {
        enable = true;
        apiKeySecret = "brave/api-key";
        braveMode = "web";
      };

      browser = {
        enable = true;
        evaluateEnabled = true;
        headless = false;
        package = pkgs.chromium;
        executablePath = "${pkgs.chromium}/bin/chromium";
      };

      canvas = {
        enable = true;
        nodePackage = pkgs.nodejs;
      };

      desktopNode = {
        enable = true;
        user = "buddia";
        displayName = "alan-framework-desktop";
        gatewayHost = null;
      };

      extraConfig = {
        commands.bash = true;

        tools = {
          elevated = {
            enabled = true;
            allowFrom.telegram = [
              "id:7336229793"
              "id:5255330939"
            ];
          };

          exec = {
            host = "gateway";
            security = "full";
            ask = "off";
            pathPrepend = [
              "/run/wrappers/bin"
              "/run/current-system/sw/bin"
              "/nix/var/nix/profiles/default/bin"
            ];
          };
        };
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
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-framework".path;
      };
    };
  };
}
