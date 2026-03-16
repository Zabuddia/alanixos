{ pkgs, hostname, config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ./users.nix
    ./wireguard.nix
    ../../modules/llm.nix
    ../../modules/openclaw.nix
    ../../modules/desktop
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
  ];

  alanix.desktop.enable = true;

  # Identity
  networking.hostName = hostname;
  time.timeZone = "America/Denver";
  system.stateVersion = "25.11";

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Host basics
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix basics
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  programs.nix-ld.enable = true;

  # Networking
  networking.networkmanager.enable = true;
  services.tailscale.extraSetFlags = [ "--operator=openclaw" ];

  # Firewall
  networking.firewall.enable = true;

  # Cloudflare DDNS
  services.cloudflare-ddns = {
    enable = true;
    domains = [ "alan-framework-wg.fifefin.com" ];
    credentialsFile = config.sops.templates."cloudflare-env".path;
    provider.ipv6 = "none";
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

  # Basic tools
  environment.systemPackages = with pkgs; [
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
}
