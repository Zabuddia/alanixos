{ pkgs, hostname, config, ... }:
let
  openclawRebuild = pkgs.writeShellScriptBin "openclaw-rebuild" ''
    exec /run/current-system/sw/bin/nixos-rebuild switch --flake path:/home/buddia/.nixos#alan-framework
  '';
in
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
  programs.git = {
    enable = true;
    config.safe.directory = [
      "/home/buddia/.nixos"
      "/home/buddia/alanixos"
    ];
  };

  # Networking
  networking.networkmanager.enable = true;
  services.tailscale.extraSetFlags = [ "--operator=openclaw" ];

  security.sudo.extraRules = [
    {
      users = [ "openclaw" ];
      runAs = "root:root";
      commands = [
        {
          command = "${openclawRebuild}/bin/openclaw-rebuild";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  system.activationScripts.openclawRepoAccess.text = ''
    ${pkgs.acl}/bin/setfacl -m u:openclaw:rx /home/buddia

    for repo in /home/buddia/.nixos /home/buddia/alanixos; do
      if [ -e "$repo" ]; then
        ${pkgs.acl}/bin/setfacl -R -m u:openclaw:rwX "$repo"
        ${pkgs.findutils}/bin/find "$repo" -type d -exec ${pkgs.acl}/bin/setfacl -m d:u:openclaw:rwX '{}' +
      fi
    done
  '';

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
    host = "127.0.0.1";
    listenHost = "0.0.0.0";
    model = {
      name = "qwen3.5-35b-a3b";
      hfRepo = "unsloth/Qwen3.5-35B-A3B-GGUF";
      hfFile = "Qwen3.5-35B-A3B-UD-Q5_K_XL.gguf";
      # name = "qwen3.5-122b-a10b";
      # hfRepo = "unsloth/Qwen3.5-122B-A10B-GGUF:Q3_K_S";
    };
    ctxSize = 262144;
    # ctxSize = 131072;
    gpuLayers = "all";
    parallel = 2;
  };

  alanix.openclaw = {
    enable = true;
    bind = "loopback";
    port = 18789;
    enableResponsesApi = true;
    enableChatCompletionsApi = true;
    enableTailscaleServe = true;
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
            nostr = [
              "npub1yfuharj8jmlld3qwuffk2zc0lvsc3ajptvyt5v3cnwfltaugy0fs4dl80d"
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

    # bash ./scripts/install-openclaw-nostr
    # npub137vv20ctylhalqcyu783wxe6q9fqfnf2f76tyltkg8pj8m5ejcwsftxzqz
    nostr = {
      enable = true;
      dmPolicy = "allowlist";
      allowFrom = [ "npub1yfuharj8jmlld3qwuffk2zc0lvsc3ajptvyt5v3cnwfltaugy0fs4dl80d" ];
      relays = [
        "wss://relay.damus.io"
        "wss://nos.lol"
        "wss://relay.primal.net"
      ];
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
    openclawRebuild
  ];
}
