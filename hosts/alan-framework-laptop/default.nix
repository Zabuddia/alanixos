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
        lsof
        nak
        nodejs
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
        p7zip
        unar
        gparted
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
        extraGroups = [ "wheel" "networkmanager" "input" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExSf9y7yGFQySwkx42MXCgZ6EkgP2PebAJb4++5X0SB fife.alan@protonmail.com";
        authorizedHosts = [ "alan-big-nixos" "alan-framework" "alan-laptop-nixos" "alan-node" "alan-optiplex" "randy-big-nixos" ];

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
            remmina
            tor-browser
            hyprpicker
            zoom-us
            usbimager
            tmux
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
          matchBlocks = {
            "github-personal" = {
              hostname = "github.com";
              user = "git";
              identityFile = config.sops.secrets."ssh-private-keys/alan-framework-laptop".path;
              identitiesOnly = true;
              controlPath = "none";
            };

            "github-work" = {
              hostname = "github.com";
              user = "git";
              identityFile = config.sops.secrets."ssh-private-keys/alan-laptop-nixos-work".path;
              identitiesOnly = true;
              controlPath = "none";
            };
          };
        };

        desktop.enable = true;
        azahar.enable = true;
        chromium.enable = true;
        dolphin.enable = true;
        librewolf.enable = true;
        melonds.enable = true;
        nextcloudClient.enable = true;
        ryubing.enable = true;
        syncthingTray.enable = true;
        trayscale.enable = true;
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      loginKeyring.enable = true;
      bluetooth.enable = true;
      createHeadlessOutput = false;
      swayOutputRules = [
        "output eDP-1 scale 1"
      ];
      idle = {
        lockSeconds = 300;
        displayOffSeconds = 330;
        suspendSeconds = null;
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
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnWireguard = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMjMV4eEzBRCwDXDTFNwScsfHEGlACDy7YFvVP4w0nNZ buddia@alan-big-nixos";
    };

    alanix.ddns = {
      enable = true;
      provider = "cloudflare";
      domains = [ "alan-framework-laptop-wg.fifefin.com" ];
      credentialsFile = config.sops.templates."cloudflare-env".path;
    };

    alanix.wireguard = {
      enable = true;
      vpnIP = "10.100.0.5";
      endpoint = "alan-framework-laptop-wg.fifefin.com:51820";
      publicKey = "c53UWUaifmepkb9vmZC00tEcHOJHK2jmDSDNP50F3QI=";
      privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
      listenPort = 51820;
      peers = [
        "alan-big-nixos"
        "randy-big-nixos"
        "alan-framework"
        "alan-laptop-nixos"
        "alan-node"
        "alan-optiplex"
      ];
    };

    alanix.tor = {
      enable = true;
      socksPort = 9050;
    };

    alanix.tailscale = {
      enable = true;
      address = "alan-framework-laptop";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi.networks = [
      { ssid = "Cinnamon Tree"; pskSecret = "wifi-passwords/cinnamon-tree"; }
    ];

    users.groups.navidrome = {};

    alanix.syncthing = {
      enable = true;
      transport = "tailscale";
      deviceId = "C5U3HBI-EGMCLVU-CZ7EFQX-2SAASIT-ABPMTWV-N2M6TU5-NX4SHIJ-L6IL6AX";
      listenPort = 22000;
      peers = [
        "alan-big-nixos"
        "alan-node"
        "alan-framework"
        "randy-big-nixos"
      ];
      folderSets = [ "emulation" "navidrome-media" ];
      linkFolderSets = [ "emulation" ];
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
