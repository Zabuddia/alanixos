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
        lsof
        nak
        nodejs
        python3
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

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILb22RXxaO/RmZkheVk+Ma9WBXABHN/IrDGq5RbBIunC fife.alan@protonmail.com";
        authorizedHosts = [ "alan-big-nixos" "alan-framework-laptop" "alan-laptop-nixos" "randy-big-nixos" ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = {
            ".config/systemd/user/openclaw-gateway.service.d/10-path.conf" = {
              text = ''
                [Service]
                Environment=PATH=/home/buddia/.local/bin:/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin
              '';
              source = null;
              force = true;
              executable = null;
            };
          };
          packages = [ ];
          unstablePackages = with pkgs-unstable; [ yt-dlp ];
          modules = [
            {
              home.sessionPath = [ "/home/buddia/.local/bin" ];
              home.sessionVariables = {
                NPM_CONFIG_PREFIX = "/home/buddia/.local";
                NODE_PATH = "/home/buddia/.local/lib/node_modules";
              };
            }
          ];
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

        desktop.enable = true;
        azahar.enable = true;
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
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJKhkgpVCtwYKMoUpybQejUcyAcuDTRdEk0981whwds";
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
        "alan-framework-laptop"
        "alan-laptop-nixos"
      ];
    };

    alanix.tailscale = {
      enable = true;
      address = "alan-framework";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      deviceId = "EKNKF5K-6DW57FP-M2LGDA4-NTASEPT-EWD5GCI-KCSIOXJ-LO3PZFC-A6CWOAH";
      listenPort = 22000;
      peers = [
        "alan-big-nixos"
        "alan-framework-laptop"
      ];
      folderSets = [ "emulation" ];
      linkFolderSets = [ "emulation" ];
    };

    alanix.llm = {
      enable = true;
      backend = "vulkan";
      stateDir = "/var/lib/llm";
      litellm = {
        enable = true;
        host = "0.0.0.0";
        port = 4000;
      };
      instances = {
        chat = {
          enable = true;
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8080;
          alias = null;
          ctxSize = 32768;
          batchSize = 4096;
          ubatchSize = 1024;
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
          extraArgs = [ "--swa-full" ];
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
