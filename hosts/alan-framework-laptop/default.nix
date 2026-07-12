{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
    ];

    # BIOS 3.05 exposes an unwired AMD ACP/PDM microphone on the Framework 13
    # Ryzen AI 300. Prevent it from hiding the real ALC285 analog microphone.
    # https://github.com/FrameworkComputer/SoftwareFirmwareIssueTracker/issues/166
    boot.blacklistedKernelModules = [
      "snd_acp70"
      "snd_acp_pci"
    ];

    # Keep PipeWire/WebRTC from driving the ALC285 hardware mixer back to its
    # noisy +30 dB capture and +30 dB boost defaults when recording starts.
    services.pipewire.wireplumber.extraConfig."51-framework-internal-mic" = {
      "monitor.alsa.rules" = [
        {
          matches = [
            {
              "node.name" = "alsa_input.pci-0000_c1_00.6.analog-stereo";
            }
          ];
          actions.update-props = {
            "api.alsa.soft-mixer" = true;
            "api.alsa.disable-mixer-path" = true;
          };
        }
      ];
    };

    # Pin the internal microphone path to conservative hardware gain. PipeWire
    # handles any further volume adjustment in software.
    systemd.user.services.framework-internal-mic-gain = {
      description = "Set sane Framework internal microphone gain";
      wantedBy = [ "default.target" ];
      wants = [ "wireplumber.service" ];
      after = [ "wireplumber.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.alsa-utils}/bin/amixer --card Generic_1 set 'Internal Mic' cap
        ${pkgs.alsa-utils}/bin/amixer --card Generic_1 cset name='Internal Mic Boost Volume' 0,0
        ${pkgs.alsa-utils}/bin/amixer --card Generic_1 cset name='Capture Volume' 30,30
      '';
    };

    services.joycond.enable = true;

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
        lsof
        nak
        nodejs
        ripgrep
        python3
        restic
        sops
        tree
        wget
        vlc
        ffmpeg
        w_scan2
        nano
        imagemagick
        unzip
        zip
        p7zip
        parted
        dosfstools
        unar
        gparted
        usbutils
      ];
      swapDevices = [
        {
          device = "/swapfile";
          size = 20480;
        }
      ];
    };

    alanix.users = {
      mutableUsers = false;
      accounts.buddia = {
        enable = true;
        isNormalUser = true;
        extraGroups = [ "wheel" "networkmanager" "input" "kvm" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExSf9y7yGFQySwkx42MXCgZ6EkgP2PebAJb4++5X0SB fife.alan@protonmail.com";
        authorizedHosts = [ "alan-big-nixos" "alan-framework" "alan-laptop-nixos" "alan-node" "alan-optiplex" "alan-tv" "fife-tv" "randy-big-nixos" ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = { };
          packages = with pkgs; [
            featherpad
            marktext
            xournalpp
            libreoffice
            lrcget
            kid3
            remmina
            tor-browser
            hyprpicker
            wdisplays
            zoom-us
            usbimager
            tmux
            android-studio
          ];
          unstablePackages = with pkgs-unstable; [
            yt-dlp
            gimp
            firefox
            moonlight-qt
            sparrow
          ];
          modules = [
            {
              home.sessionPath = [ "/home/buddia/.local/bin" ];
              home.sessionVariables = {
                NPM_CONFIG_PREFIX = "/home/buddia/.local";
                NODE_PATH = "/home/buddia/.local/lib/node_modules";
              };
            }
          ];
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

        ssh = {
          enable = true;
          settings = {
            "github-personal" = {
              HostName = "github.com";
              User = "git";
              IdentityFile = config.sops.secrets."ssh-private-keys/alan-framework-laptop".path;
              IdentitiesOnly = true;
              ControlPath = "none";
            };

            "github-work" = {
              HostName = "github.com";
              User = "git";
              IdentityFile = config.sops.secrets."ssh-private-keys/alan-laptop-nixos-work".path;
              IdentitiesOnly = true;
              ControlPath = "none";
            };
          };
        };

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
          iptvSimple = {
            enable = true;
            m3uUrl = "http://192.168.10.105/lineup.m3u";
          };
        };
        dolphin = {
          enable = true;
          gameDirs = [
            "${config.alanix.syncthing.syncRoot}/games/roms/gamecube"
            "${config.alanix.syncthing.syncRoot}/games/roms/wii"
          ];
        };
        eden = {
          enable = true;
          gameDirs = [ "${config.alanix.syncthing.syncRoot}/games/roms/switch" ];
        };
        evdevhook2.enable = true;
        librewolf.enable = true;
        melonds.enable = true;
        nextcloudClient.enable = true;
        retroarch.enable = true;
        ryubing = {
          enable = true;
          gameDirs = [ "${config.alanix.syncthing.syncRoot}/games/roms/switch" ];
        };
        syncthingTray.enable = true;
        trayscale.enable = true;
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      profile = "sway";
      bluetooth.enable = true;
      bluetooth.allowUnbondedClassicHid = true;
      fingerprint.enable = true;
      gaming = {
        enable = true;
        steam.enable = true;
        packages = with pkgs; [
          gamescope
          heroic
          mangohud
          mesa-demos
          protonup-qt
          vulkan-tools
        ];
      };
      printing.enable = true;
      profiles.sway = {
        loginKeyring.enable = true;
        createHeadlessOutput = false;
        outputRules = [
          "output eDP-1 scale 1"
        ];
        idle = {
          lockSeconds = 300;
          displayOffSeconds = 330;
          suspendSeconds = null;
        };
      };
      flatpak.packages = [
        "app.openbubbles.OpenBubbles"
      ];
    };

    alanix.power = {
      enable = true;
      enablePowerProfilesDaemon = true;
      enableUpower = true;
      enableThermald = true;
      enablePowertop = true;
      lidSwitch = {
        enable = true;
        action = "suspend-then-hibernate";
        externalPowerAction = "suspend-then-hibernate";
        dockedAction = "ignore";
      };
      hibernate = {
        enable = true;
        resumeSwapFile = "/swapfile";
        suspendThenHibernateDelay = "30min";
        hibernateOnACPower = false;
      };
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMjMV4eEzBRCwDXDTFNwScsfHEGlACDy7YFvVP4w0nNZ buddia@alan-big-nixos";
    };
    alanix.tor = {
      enable = true;
      socksPort = 9050;
    };

    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = "alan-framework-laptop";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi.networks = [
      { ssid = "OpenWrt"; pskSecret = "wifi-passwords/OpenWrt"; }
    ];

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      deviceId = "C5U3HBI-EGMCLVU-CZ7EFQX-2SAASIT-ABPMTWV-N2M6TU5-NX4SHIJ-L6IL6AX";
      listenPort = 22000;
      peers = [
        "alan-big-nixos"
        "alan-framework"
        "alan-optiplex"
        "alan-tv"
        "randy-big-nixos"
      ];
      folderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-eden"
        "emulation-melonds"
        "emulation-n64"
        "emulation-retroarch"
        "emulation-ryujinx"
        "videos"
        "music"
        "audiobooks"
        "ebooks"
        "filebrowser-buddia-files"
      ];
      linkFolderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-eden"
        "emulation-melonds"
        "emulation-ryujinx"
      ];
      externalDevices.pixel-fold = {
        id = "BT23SPJ-ICTEBQ7-GJTDRQT-LCUQ773-U63QFZR-472O3YA-2KRJ4KY-AMPZ7AF";
        addresses = [ "tcp://pixel-fold:22000" ];
        folderSets = [
          "ebooks"
          "filebrowser-buddia-files"
          "emulation-azahar"
          "emulation-dolphin"
          "emulation-melonds"
          "emulation-n64"
          "emulation-retroarch"
          "videos"
        ];
      };
    };

    alanix.remote-desktop = {
      enable = true;
      autoStart = false;
      port = 5900;
      output = null;
    };

    alanix.sunshine = {
      enable = true;
      autoStart = false;
      openFirewall = false;
      capSysAdmin = true;
      webUi = {
        port = 47990;
        username = "buddia";
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-framework-laptop".path;
      };
    };
  };
}
