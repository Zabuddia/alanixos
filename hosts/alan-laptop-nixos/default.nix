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
        extraGroups = [ "wheel" "networkmanager" "input" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNJ7KX0IIt27KqD2c3dqMT8vbO0K/G1ibfC+a/WxijO fife.alan@protonmail.com";
        authorizedHosts = [ "alan-big-nixos" "alan-framework" "alan-framework-laptop" "alan-node" "alan-optiplex" "alan-tv" "fife-tv" "randy-big-nixos" ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = {
            ".ssh/id_ed25519_work.pub" = {
              text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZHjKqhqWZalx6/NsQv1OGXJP6LBMfXS0QedqwhjFzl briggsconsulting.coaching@gmail.com";
              source = null;
              force = true;
              executable = null;
            };
          };
          packages = with pkgs; [
            featherpad
            marktext
            xournalpp
            libreoffice
            remmina
            tor-browser
            hyprpicker
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
              IdentityFile = config.sops.secrets."ssh-private-keys/alan-laptop-nixos".path;
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
        dolphin = {
          enable = true;
          gameDirs = [
            "${config.alanix.syncthing.syncRoot}/games/roms/gamecube"
            "${config.alanix.syncthing.syncRoot}/games/roms/wii"
          ];
        };
        librewolf.enable = true;
        melonds.enable = true;
        nextcloudClient.enable = true;
        ryubing = {
          enable = true;
          gameDirs = [ "${config.alanix.syncthing.syncRoot}/games/roms/switch" ];
        };
        trayscale.enable = true;
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      profile = "sway";
      profiles.sway = {
        createHeadlessOutput = false;
        outputRules = [ ];
        idle = {
          lockSeconds = 300;
          displayOffSeconds = 330;
          suspendSeconds = null;
        };
      };
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
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJx7XE3EZOH49dap2q3IVLRjvf/Zb052puyJPjr+LBOM";
    };
    alanix.tor = {
      enable = true;
      socksPort = 9050;
    };

    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi.networks = [
      { ssid = "OpenWrt"; pskSecret = "wifi-passwords/OpenWrt"; }
    ];

    alanix.syncthing.deviceId = "OXKT6UP-LWKYRF4-XJ6YR5P-MOHU27R-5ZSHMVI-O4XJK2T-2IHVMFO-OKZC3AO";

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
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-laptop-nixos".path;
      };
    };
  };
}
