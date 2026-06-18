{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
      ../../modules/services/bitcoin
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
        android-tools
        bind
        caddy
        curl
        git
        htop
        jq
        lm_sensors
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
        extraGroups = [ "wheel" "networkmanager" "input" "cdrom" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJagVnL05ndecnIntQQbEUFs9EMxVP/27oGNuZGAjpbJ fife.alan@protonmail.com";
        authorizedHosts = [
          "alan-big-nixos"
          "alan-framework"
          "alan-framework-laptop"
          "alan-laptop-nixos"
          "alan-node"
          "alan-tv"
          "fife-tv"
          "randy-big-nixos"
        ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = { };
          packages = with pkgs; [
            abcde
            asunder
            cdparanoia
            cuetools
            easytag
            ffmpeg
            flac
            freac
            glyr
            handbrake
            kid3
            lame
            mediainfo
            mp3val
            opus-tools
            picard
            tmux
            vlc
            vorbis-tools
            whipper
          ];
          unstablePackages = with pkgs-unstable; [
            yt-dlp
            moonlight-qt
          ];
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
        azahar.enable = true;
        chromium.enable = true;
        makemkv = {
          enable = true;
          betaKey = "T-sJ5R5BKxhD671U9s0teXbyP19MhCkkkB7rmnNbb1aEHaqveiVqyI3RXGMHDXhoyNUC";
        };
        dolphin = {
          enable = true;
          gameDirs = [
            "${config.alanix.syncthing.syncRoot}/games/roms/gamecube"
            "${config.alanix.syncthing.syncRoot}/games/roms/wii"
          ];
        };
        melonds.enable = true;
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      profile = "sway";
      bluetooth.enable = true;
      profiles.sway = {
        autoLogin = {
          enable = true;
          user = "buddia";
        };
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
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHtRq4i0HdUGbcB2XnUjnnvHbUp2tEu9TwQjUiKjmTbY";
    };
    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = "alan-optiplex";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi.radio.enable = false;

    services.avahi.enable = true;

    fileSystems."/home/buddia/storage" = {
      device = "/dev/disk/by-uuid/1e1a79ae-0312-4f3b-81ce-66fca54202ba";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=10s" ];
    };

    systemd.tmpfiles.rules = [
      "d /home/buddia/storage 0755 buddia users - -"
    ];

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      syncRoot = "/home/buddia/storage/Syncthing";
      listenPort = 22000;
      folderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "movies"
        "shows"
        "videos"
        "music"
        "audiobooks"
        "ebooks"
      ];
      linkFolderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
      ];
      deviceId = "2BGWQTB-75JJCIW-OEWFP4L-Y2BTROG-IYJ2ESY-IAQ5CIO-QGOXUYW-GBM5HA4";
      peers = [
        "alan-big-nixos"
        "alan-framework"
        "alan-framework-laptop"
        "alan-node"
        "alan-tv"
        "randy-big-nixos"
      ];
      externalDevices.pixel-fold = {
        id = "BT23SPJ-ICTEBQ7-GJTDRQT-LCUQ773-U63QFZR-472O3YA-2KRJ4KY-AMPZ7AF";
        addresses = [ "tcp://pixel-fold:22000" ];
        folderSets = [
          "emulation-azahar"
          "emulation-dolphin"
          "emulation-melonds"
          "videos"
        ];
      };
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
