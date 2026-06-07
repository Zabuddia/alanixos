{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
    ];

    alanix.system = {
      stateVersion = "26.05";
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
      swapDevices = [ ];
    };

    alanix.users = {
      mutableUsers = false;
      accounts.buddia = {
        enable = true;
        isNormalUser = true;
        extraGroups = [ "wheel" "networkmanager" "input" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJhIOpVi6T5JO3hzG/OOtKwZscOBBbwSD1WOoBh012RL fife.alan@protonmail.com";
        authorizedHosts = [
          "alan-big-nixos"
          "alan-framework"
          "alan-framework-laptop"
          "alan-laptop-nixos"
          "alan-node"
          "alan-optiplex"
          "randy-big-nixos"
        ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "26.05";
          files = { };
          packages = with pkgs; [
            handbrake
            tmux
            vlc
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
        antimicrox = {
          enable = true;
          mouse.precisionButton = "rb";
          workspaceSwitching.enable = true;
          openThunar.path = "${config.alanix.users.accounts.buddia.home.directory}/Syncthing/media";
          openScrcpy.extraArgs = [ "--fullscreen" ];
          pauseForApps = [ "kodi" ];
          pauseForGameApps = [ "dolphin-emu" ];
          pauseForGameAppTitlePatterns.Ryujinx = [
            ''\([[:xdigit:]]{16}\) \([[:digit:]]+-bit\)$''
          ];
          gameButtonActions.guide = "escape";
          gameButtonActionApps = [ "Ryujinx" ];
          buttonActions = {
            a = "leftClick";
            b = "rightClick";
            x = "openDolphin";
            y = "openRyubing";
            back = "escape";
            start = "enter";
            lb = "closeWindow";
            leftStick = "keyboard";
            rightStick = "launcher";
            leftTrigger = "openScrcpy";
            rightTrigger = "openKodi";
          };
          controllerGuids = [
            "0300f6b6c82d00000b310000140100001172012555B92A5226DA"
          ];
        };
        chromium.enable = true;
        makemkv = {
          enable = true;
          betaKey = "T-sJ5R5BKxhD671U9s0teXbyP19MhCkkkB7rmnNbb1aEHaqveiVqyI3RXGMHDXhoyNUC";
        };
        kodi = {
          enable = true;
          invidious = {
            enable = true;
            instanceUrl = "https://invidious.fifefin.com";
            username = "buddia";
            passwordFile = config.sops.secrets."invidious-passwords/buddia".path;
            markItemsWatched = true;
          };
          jellyfin.enable = true;
          inputstreamAdaptive = {
            enable = true;
            streamSelectionType = "fixed-res";
            maxResolution = "1080p";
            secureMaxResolution = "1080p";
            autoInitialBandwidth = false;
            initialBandwidthKbps = 25000;
            ignoreScreenResolution = true;
            ignoreScreenResolutionChanges = true;
          };
          mediaSources.video = [
            { name = "Videos"; path = "${config.alanix.syncthing.syncRoot}/media/videos"; }
          ];
          mediaSources.music = [
            { name = "Music"; path = "${config.alanix.syncthing.syncRoot}/media/music"; }
          ];
          iptvSimple = {
            enable = true;
            m3uUrl = "http://192.168.10.105/lineup.m3u";
          };
          remoteControl = {
            enable = true;
            port = 8080;
            requireAuthentication = false;
          };
        };
        dolphin = {
          enable = true;
          gameDirs = [
            "${config.alanix.syncthing.syncRoot}/games/roms/gamecube"
            "${config.alanix.syncthing.syncRoot}/games/roms/wii"
          ];
        };
        melonds.enable = true;
        ryubing = {
          enable = true;
          confirmExit = false;
          gameDirs = [ "${config.alanix.syncthing.syncRoot}/games/roms/switch" ];
          startFullscreen = true;
        };
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
        hideCursorMs = 1000;
      };
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGL6zUAG5IhWFdlcfxcOSAEzTTmf0nRwEh4gPg+/TrJM alan-tv";
    };
    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = "alan-tv";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi = {
      radio.enable = true;
      networks = [
        { ssid = "OpenWrt"; pskSecret = "wifi-passwords/OpenWrt"; }
      ];
    };

    services.avahi.enable = true;

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      listenPort = 22000;
      folderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "emulation-ryujinx"
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
        "emulation-ryujinx"
      ];
      deviceId = "OQE4RP7-C457Q5O-GYEPFIN-YNNEGWH-A7KFH3E-LYTMYOL-GJ6VLU4-EKTRLAP";
      peers = [
        "alan-big-nixos"
        "alan-framework"
        "alan-framework-laptop"
        "alan-node"
        "alan-optiplex"
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
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-tv".path;
      };
    };
  };
}
