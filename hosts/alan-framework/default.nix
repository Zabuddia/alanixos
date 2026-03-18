{ pkgs, hostname, config, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ../../modules/roles/server.nix
    ../../modules/services/llm.nix
    ../../modules/services/openclaw.nix
    ../../modules/services/remote-desktop.nix
  ];

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

  home-manager.users.buddia = {
    home.file.".ssh/id_ed25519.pub" = {
      text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILb22RXxaO/RmZkheVk+Ma9WBXABHN/IrDGq5RbBIunC fife.alan@protonmail.com";
      force = true;
    };
  };

  alanix.llm = {
    enable = true;
    backend = "vulkan";
    instances = {
      chat = {
        enable = true;
        host = "127.0.0.1";
        listenHost = "0.0.0.0";
        port = 8080;
        model = {
          name = "qwen3.5-35b-a3b";
          hfRepo = "unsloth/Qwen3.5-35B-A3B-GGUF";
          hfFile = "Qwen3.5-35B-A3B-UD-Q5_K_XL.gguf";
        };
        ctxSize = 262144;
        gpuLayers = "all";
        parallel = 1;
      };

      vision = {
        enable = true;
        host = "127.0.0.1";
        listenHost = "0.0.0.0";
        port = 8081;
        input = [ "text" "image" ];
        model = {
          name = "qwen3-vl-30b-a3b-instruct";
          hfRepo = "unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF";
          hfFile = "Qwen3-VL-30B-A3B-Instruct-Q4_K_M.gguf";
          mmprojUrl = "https://huggingface.co/unsloth/Qwen3-VL-30B-A3B-Instruct-GGUF/resolve/main/mmproj-F16.gguf";
        };
        ctxSize = 32768;
        gpuLayers = "all";
        parallel = 1;
      };

      embeddings = {
        enable = true;
        host = "127.0.0.1";
        listenHost = "0.0.0.0";
        port = 8082;
        model = {
          name = "qwen3-embedding-4b";
          hfRepo = "Qwen/Qwen3-Embedding-4B-GGUF";
          hfFile = "Qwen3-Embedding-4B-Q5_K_M.gguf";
        };
        ctxSize = 8192;
        gpuLayers = "all";
        parallel = 1;
        extraArgs = [ "--embeddings" ];
      };
    };
  };

  alanix.openclaw = {
    enable = true;
    bind = "loopback";
    port = 18789;
    enableResponsesApi = true;
    enableChatCompletionsApi = true;
    enableTailscaleServe = true;
    primaryLlmInstance = "chat";
    imageLlmInstance = "vision";
    embeddingLlmInstance = "embeddings";
    controlUi = {
      allowedOrigins = [
        "https://alan-framework.tailbb2802.ts.net"
      ];
      dangerouslyDisableDeviceAuth = true;
    };

    extraConfig = {
      commands.bash = true;

      tools = {
        elevated = {
          enabled = true;
          allowFrom = {
            telegram = [
              "id:7336229793"
              "id:5255330939"
            ];
          };
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

    telegram = {
      enable = true;
      allowFrom = [ 7336229793 5255330939 ];
    };

    webSearch.enable = true;

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
    };
  };
}
