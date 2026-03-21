{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: let
    systemPackages = with pkgs; [
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
  in {
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
      packages = systemPackages;
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
          unstablePackages = with pkgs-unstable; [ yt-dlp ];
          files.".ssh/id_ed25519.pub" = {
            text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILb22RXxaO/RmZkheVk+Ma9WBXABHN/IrDGq5RbBIunC fife.alan@protonmail.com";
            force = true;
          };
        };

        git = {
          enable = true;
          github.user = "zabuddia";
          user.name = "Alan Fife";
          user.email = "fife.alan@protonmail.com";
          init.defaultBranch = "main";
        };

        sh.enable = true;
        chromium.enable = true;
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

    alanix.desktop.enable = true;

    alanix.remote-desktop = {
      enable = true;
      port = 5900;
      user = "buddia";
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
          model = {
            name = "qwen3.5-35b-a3b";
            hfRepo = "unsloth/Qwen3.5-35B-A3B-GGUF";
            hfFile = "Qwen3.5-35B-A3B-UD-Q5_K_XL.gguf";
          };
          extraArgs = [ ];
        };

        vision = {
          enable = true;
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8081;
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
          input = [ "text" "image" ];
          model = {
            name = "qwen3-vl-30b-a3b-instruct";
            hfRepo = "unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF";
            hfFile = "Qwen3-VL-30B-A3B-Instruct-Q4_K_M.gguf";
            mmprojUrl = "https://huggingface.co/unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF/resolve/main/mmproj-F16.gguf";
          };
          extraArgs = [ ];
        };

        embeddings = {
          enable = true;
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8082;
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
          model = {
            name = "qwen3-embedding-4b";
            hfRepo = "Qwen/Qwen3-Embedding-4B-GGUF";
            hfFile = "Qwen3-Embedding-4B-Q5_K_M.gguf";
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
  };
}
