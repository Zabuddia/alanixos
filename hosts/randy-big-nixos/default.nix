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
        python3
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

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKpHeGMaMDqWna8I5fu0K2kaZ1GdOFIGw+8NsgH3aXE3 fife.alan@protonmail.com";

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = { };
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

        desktop.enable = true;
        chromium.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      createHeadlessOutput = false;
      swayOutputRules = [ ];
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
  };
}
