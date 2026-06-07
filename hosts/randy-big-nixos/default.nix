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
        bind
        caddy
        curl
        git
        htop
        iotop
        jq
        ripgrep
        python3
        restic
        sops
        tree
        unzip
        p7zip
        parted
        dosfstools
        wget
        usbutils
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
        authorizedHosts = [ "alan-big-nixos" "alan-framework" "alan-framework-laptop" "alan-laptop-nixos" "alan-node" "alan-optiplex" "alan-tv" ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = { };
          packages = with pkgs; [
            lrcget
            tmux
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

        desktop = {
          enable = true;
          profile = "sway/default";
        };
        chromium.enable = true;
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

    alanix.remote-desktop = {
      enable = true;
      autoStart = true;
      port = 5900;
      output = "HEADLESS-1";
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO5Qr4R/wUzLevox3Bl415pV20gkIL+fzfExjbkwzFy";
    };
    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = "randy-big-nixos";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.tvheadend = {
      enable = true;
      recordingsDir = "/srv/tvheadend/recordings";
      expose.tailscale = {
        enable = true;
        port = 19981;
      };
      htsp.expose.tailscale = {
        enable = true;
        port = 19982;
      };
    };

    alanix.syncthing = {
      deviceId = "WOQMMD4-ZYSB3YY-F4WFRQJ-O7T4X2A-UV54S74-Z26UPI2-DCNKC2I-ALDOWAN";
      peers = [
        "alan-big-nixos"
        "alan-framework-laptop"
        "alan-node"
        "alan-optiplex"
        "alan-tv"
      ];
    };
  };
}
