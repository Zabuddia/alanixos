{ pkgs, hostname, config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./secrets.nix
    ./users.nix
    ./wireguard.nix
    ../../modules/llm.nix
    ../../modules/openclaw.nix
    ../../modules/sway.nix
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
  ];

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

  # Networking
  networking.networkmanager.enable = true;

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
    model = {
      name = "qwen3.5-35b-a3b";
      hfRepo = "unsloth/Qwen3.5-35B-A3B-GGUF";
      hfFile = "Qwen3.5-35B-A3B-UD-Q4_K_M.gguf";
    };
    ctxSize = 32768;
    gpuLayers = "all";
    parallel = 4;
  };

  alanix.openclaw = {
    enable = true;
    bind = "tailnet";
    port = 18789;
    enableResponsesApi = true;
    enableChatCompletionsApi = true;
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
