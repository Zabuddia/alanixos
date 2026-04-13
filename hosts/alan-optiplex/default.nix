{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
      ../../clusters/home.nix
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
        unzip
        p7zip
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

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJagVnL05ndecnIntQQbEUFs9EMxVP/27oGNuZGAjpbJ fife.alan@protonmail.com";
        authorizedHosts = [
          "alan-big-nixos"
          "alan-framework"
          "alan-framework-laptop"
          "alan-laptop-nixos"
          "alan-node"
          "randy-big-nixos"
        ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = { };
          packages = with pkgs; [
            handbrake
          ];
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
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHtRq4i0HdUGbcB2XnUjnnvHbUp2tEu9TwQjUiKjmTbY";
    };

    alanix.ddns = {
      enable = true;
      provider = "cloudflare";
      domains = [ "alan-optiplex-wg.fifefin.com" ];
      credentialsFile = config.sops.templates."cloudflare-env".path;
    };

    alanix.wireguard = {
      enable = true;
      vpnIP = "10.100.0.7";
      endpoint = "alan-optiplex-wg.fifefin.com:51820";
      publicKey = "DwCiEiQQEormDpKwx1YX9KADgp4BzPANL+LxAGUs6xc=";
      privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
      listenPort = 51820;
      peers = [
        "alan-big-nixos"
        "randy-big-nixos"
        "alan-framework"
        "alan-framework-laptop"
        "alan-laptop-nixos"
        "alan-node"
      ];
    };

    alanix.tailscale = {
      enable = true;
      address = "alan-optiplex";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.syncthing = {
      deviceId = "2BGWQTB-75JJCIW-OEWFP4L-Y2BTROG-IYJ2ESY-IAQ5CIO-QGOXUYW-GBM5HA4";
      peers = [
        "alan-big-nixos"
        "alan-node"
      ];
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
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-optiplex".path;
      };
    };
  };
}
