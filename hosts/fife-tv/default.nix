{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
    ];

    services.joycond.enable = true;

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    alanix.system = {
      stateVersion = "26.05";
      timeZone = "America/New_York";
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
        dtv-scan-tables
        git
        htop
        jq
        lm_sensors
        libva-utils
        mesa-demos
        nvtopPackages.amd
        pciutils
        radeontop
        ripgrep
        python3
        restic
        sops
        tree
        unzip
        v4l-utils
        vulkan-tools
        zip
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

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrubxri9l5fkzTpcBDPZ282glPwLgZ4ctWTiGy9drAe fife-tv";
        authorizedHosts = [
          "alan-big-nixos"
          "alan-framework"
          "alan-framework-laptop"
          "alan-laptop-nixos"
          "alan-node"
          "alan-optiplex"
          "alan-tv"
          "randy-big-nixos"
        ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "26.05";
          files = { };
          packages = with pkgs; [
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
          openThunar.path = config.alanix.users.accounts.buddia.home.directory;
          openScrcpy.extraArgs = [ "--fullscreen" ];
          pauseForApps = [ "kodi" ];
          pauseForGameApps = [ "dolphin-emu" "eden" ];
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
            "0300f6b6c82d00000b310000140100001172012555DC2A52A67D"
          ];
        };
        chromium.enable = true;
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
            { name = "Videos"; path = "${config.alanix.users.accounts.buddia.home.directory}/Videos"; }
          ];
          mediaSources.music = [
            { name = "Music"; path = "${config.alanix.users.accounts.buddia.home.directory}/Music"; }
          ];
          tvheadend.servers = [
            {
              name = "Hauppauge";
              host = "127.0.0.1";
            }
          ];
          remoteControl = {
            enable = true;
            port = 8080;
            requireAuthentication = false;
          };
        };
        dolphin = {
          enable = true;
          gameDirs = [
            "${config.alanix.users.accounts.buddia.home.directory}/Games/roms/gamecube"
            "${config.alanix.users.accounts.buddia.home.directory}/Games/roms/wii"
          ];
        };
        eden = {
          enable = true;
          confirmExit = false;
          gameDirs = [ "${config.alanix.users.accounts.buddia.home.directory}/Games/roms/switch" ];
          startFullscreen = true;
          stopEmulationControllerHotkey = "Home";
        };
        evdevhook2.enable = true;
        melonds.enable = true;
        ryubing = {
          enable = true;
          confirmExit = false;
          gameDirs = [ "${config.alanix.users.accounts.buddia.home.directory}/Games/roms/switch" ];
          startFullscreen = true;
        };
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      profile = "sway";
      bluetooth.enable = true;
      bluetooth.allowUnbondedClassicHid = true;
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

    alanix.power = {
      enable = true;
      enablePowerProfilesDaemon = true;
      enablePowertop = false;
      enableThermald = false;
      enableUpower = false;
      profile = "performance";
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJmneW6ltIDbSig5EvMqC13yClQe0riPGvjxu4z/ogFQ fife-tv";
    };
    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = "fife-tv";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi = {
      radio.enable = true;
      networks = [
        { ssid = "WIN_005356"; pskSecret = "wifi-passwords/WIN_005356"; }
      ];
    };

    services.avahi.enable = true;

    # The Mayflash DolphinBar exposes paired Wii Remotes as hidraw devices in
    # mode 4. Dolphin needs direct access to those endpoints for "Real Wii
    # Remote" input.
    services.udev.extraRules = ''
      SUBSYSTEM=="hidraw", KERNEL=="hidraw*", ATTRS{idVendor}=="057e", ATTRS{idProduct}=="0306", GROUP="input", MODE="0660", TAG+="uaccess"
    '';

    alanix.tvheadend = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9981;
      dataDir = "/var/lib/tvheadend";
      recordingsDir = "/srv/tvheadend/recordings";
      devicePaths = [ "/dev/dvb" ];
      timeZone = "America/New_York";
      epg.disableOverTheAirGrabbers = false;
      htsp = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9982;
      };
    };

    services.pipewire.wireplumber.extraConfig."51-prefer-epson-hdmi" = {
      "monitor.alsa.rules" = [
        {
          matches = [
            {
              "node.name" = "alsa_output.pci-0000_0b_00.1.hdmi-stereo-extra3";
            }
          ];
          actions.update-props."priority.session" = 1500;
        }
      ];
    };

    alanix.sunshine = {
      enable = true;
      autoStart = true;
      openFirewall = true;
      capSysAdmin = true;
      webUi = {
        port = 47990;
        username = "buddia";
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/fife-tv".path;
      };
    };
  };
}
