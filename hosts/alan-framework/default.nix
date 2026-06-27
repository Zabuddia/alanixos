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
      timeZone = "America/Chicago";
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
        bind
        caddy
        curl
        git
        htop
        jq
        lm_sensors
        lsof
        nak
        nodejs
        ripgrep
        python3
        restic
        sops
        tree
        unzip
        zip
        p7zip
        parted
        dosfstools
        wget
        usbutils
      ];
      swapDevices = [
        # This host keeps several large local models warm; swap gives the box
        # some breathing room during cache churn and prevents brief OOM outages.
        {
          device = "/swapfile";
          size = 32768;
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

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILb22RXxaO/RmZkheVk+Ma9WBXABHN/IrDGq5RbBIunC fife.alan@protonmail.com";
        authorizedHosts = [ "alan-big-nixos" "alan-framework-laptop" "alan-laptop-nixos" "alan-node" "alan-optiplex" "alan-tv" "fife-tv" "randy-big-nixos" ];

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
          packages = with pkgs; [
            tmux
          ];
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

        desktop = {
          enable = true;
          profile = "sway/default";
        };
        azahar.enable = true;
        chromium.enable = true;
        dolphin = {
          enable = true;
          gameDirs = [
            "${config.alanix.syncthing.syncRoot}/games/roms/gamecube"
            "${config.alanix.syncthing.syncRoot}/games/roms/wii"
          ];
        };
        melonds.enable = true;
        retroarch.enable = true;
        ryubing = {
          enable = true;
          gameDirs = [ "${config.alanix.syncthing.syncRoot}/games/roms/switch" ];
        };
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      profile = "sway";
      profiles.sway = {
        autoLogin = {
          enable = true;
          user = "buddia";
        };
        createHeadlessOutput = true;
        outputRules = [
          "output HEADLESS-1 resolution 1920x1080"
        ];
        idle = {
          lockSeconds = null;
          displayOffSeconds = null;
          suspendSeconds = null;
        };
      };
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJKhkgpVCtwYKMoUpybQejUcyAcuDTRdEk0981whwds";
    };
    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = "alan-framework";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi.radio.enable = false;

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      deviceId = "EKNKF5K-6DW57FP-M2LGDA4-NTASEPT-EWD5GCI-KCSIOXJ-LO3PZFC-A6CWOAH";
      listenPort = 22000;
      peers = [
        "alan-big-nixos"
        "alan-framework-laptop"
        "alan-optiplex"
        "alan-tv"
      ];
      folderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "emulation-n64"
        "emulation-retroarch"
        "emulation-ryujinx"
      ];
      linkFolderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "emulation-ryujinx"
      ];
      externalDevices.pixel-fold = {
        id = "BT23SPJ-ICTEBQ7-GJTDRQT-LCUQ773-U63QFZR-472O3YA-2KRJ4KY-AMPZ7AF";
        addresses = [ "tcp://pixel-fold:22000" ];
        folderSets = [
          "emulation-azahar"
          "emulation-dolphin"
          "emulation-melonds"
          "emulation-n64"
          "emulation-retroarch"
        ];
      };
    };

    alanix.llm = {
      enable = true;
      backend = "vulkan";
      stateDir = "/var/lib/llm";
      dashboard = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9843;
        recentLogLines = 40;
        expose = {
          tailscale = {
            enable = true;
            port = 19843;
          };
          tor = {
            enable = true;
            publicPort = 80;
            secretKeyBase64Secret = "tor/llm-dashboard/alan-framework/secret-key-base64";
            hostname = "vx4hkzxkj6s2wslxahmnm5evo5hv3xc75sdgittbnulx4g2upkhvegad.onion";
          };
        };
      };
      litellm = {
        enable = true;
        host = "0.0.0.0";
        port = 4000;
      };
      instances = {
        # Primary foreground text model for OpenClaw main chat and IDE clients.
        chat = {
          enable = true;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8083;
          alias = "qwen3.6-35b-a3b";
          ctxSize = 131072;
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
            name = "qwen3.6-35b-a3b";
            path = null;
            url = null;
            hfRepo = "unsloth/Qwen3.6-35B-A3B-GGUF";
            hfFile = "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          # OpenClaw and Open WebUI expect plain assistant content here; when
          # Qwen thinks out loud it can stall chats and return empty content.
          extraArgs = [
            "--reasoning"
            "off"
          ];
        };

        # Small fast text model for OpenClaw subagents, ops, and quick triage.
        fast = {
          enable = true;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8084;
          alias = "qwen3-8b";
          ctxSize = 40960;
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
            name = "qwen3-8b";
            path = null;
            url = null;
            hfRepo = "Qwen/Qwen3-8B-GGUF";
            hfFile = "Qwen3-8B-Q4_K_M.gguf";
            mmprojPath = null;
            mmprojUrl = null;
          };
          extraArgs = [
            "--reasoning"
            "off"
          ];
        };

        # Vision model used for image understanding.
        vision = {
          enable = true;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8081;
          alias = "qwen3-vl-30b-a3b-instruct";
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

        # Embeddings model used for OpenClaw memory search.
        embeddings = {
          enable = true;
          runtime = "llama";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8082;
          alias = "qwen3-embedding-4b";
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

        # Speech-to-text model exposed through LiteLLM's transcription endpoint.
        transcribe = {
          enable = true;
          runtime = "whisper";
          host = "127.0.0.1";
          listenHost = "0.0.0.0";
          port = 8085;
          alias = "whisper-small";
          threads = null;
          input = [ "audio" ];
          language = "auto";
          translate = false;
          processors = 1;
          convertAudio = true;
          requestPath = "/v1/audio/transcriptions";
          inferencePath = "";
          gpu = true;
          model = {
            name = "small";
            path = null;
            url = null;
            hfRepo = null;
            hfFile = null;
            mmprojPath = null;
            mmprojUrl = null;
            downloadName = "small";
          };
          extraArgs = [ ];
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
