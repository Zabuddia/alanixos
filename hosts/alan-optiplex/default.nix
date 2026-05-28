{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
    ];

    hardware.alsa.enablePersistence = true;

    system.activationScripts.alanixOptiplexHdmiAudio.text = ''
      # The Sceptre HDMI output maps to IEC958,0 and boots muted without seeded ALSA state.
      ${pkgs.alsa-utils}/bin/amixer -q -c PCH set 'IEC958',0 on || true
      ${pkgs.alsa-utils}/bin/amixer -q -c PCH set 'IEC958',1 on || true
      ${pkgs.alsa-utils}/bin/amixer -q -c PCH set 'IEC958',2 on || true
      ${pkgs.coreutils}/bin/install -d -m 0755 /var/lib/alsa
      ${pkgs.alsa-utils}/bin/alsactl store -gU || true
    '';

    systemd.services.alanix-optiplex-hdmi-audio = {
      description = "Enable OptiPlex HDMI audio";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sound.target" ];
      after = [ "sound.target" "alsa-store.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        # The Sceptre HDMI output maps to IEC958,0 and boots muted without seeded ALSA state.
        ${pkgs.alsa-utils}/bin/amixer -q -c PCH set 'IEC958',0 on || true
        ${pkgs.alsa-utils}/bin/amixer -q -c PCH set 'IEC958',1 on || true
        ${pkgs.alsa-utils}/bin/amixer -q -c PCH set 'IEC958',2 on || true
        ${pkgs.coreutils}/bin/install -d -m 0755 /var/lib/alsa
        ${pkgs.alsa-utils}/bin/alsactl store -gU || true
      '';
    };

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
          pauseForApps = [ "kodi" ];
          pauseForGameApps = [ "dolphin-emu" ];
          buttonActions = {
            a = "leftClick";
            b = "rightClick";
            x = "openDolphin";
            y = "keyboard";
            back = "escape";
            guide = "launcher";
            start = "enter";
            lb = "closeWindow";
            leftStick = "altTab";
            rightStick = "middleClick";
            leftTrigger = "openThunar";
            rightTrigger = "openKodi";
          };
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
          mediaSources = {
            video = [
              { name = "Movies"; path = "${config.alanix.syncthing.syncRoot}/media/movies"; }
              { name = "TV Shows"; path = "${config.alanix.syncthing.syncRoot}/media/shows"; }
            ];
            music = [
              { name = "Music"; path = "${config.alanix.syncthing.syncRoot}/media/music"; }
            ];
          };
          tvheadend.servers = [
            { name = "alan-big-nixos"; host = "alan-big-nixos"; htspPort = 19982; httpPort = 19981; }
          ];
        };
        dolphin.enable = true;
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

    alanix.wifi.radio.enable = false;

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      listenPort = 22000;
      folderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "jellyfin-media"
        "navidrome-media"
        "audiobookshelf-media"
        "kavita-media"
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
        "randy-big-nixos"
      ];
      externalDevices.pixel-fold = {
        id = "BT23SPJ-ICTEBQ7-GJTDRQT-LCUQ773-U63QFZR-472O3YA-2KRJ4KY-AMPZ7AF";
        addresses = [ "tcp://pixel-fold:22000" ];
        folderSets = [
          "emulation-azahar"
          "emulation-dolphin"
          "emulation-melonds"
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
