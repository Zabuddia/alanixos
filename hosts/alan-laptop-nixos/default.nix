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
        authorizedHosts = [ "alan-big-nixos" "alan-framework" "alan-framework-laptop" "alan-node" "randy-big-nixos" ];

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
          matchBlocks = {
            "github-personal" = {
              hostname = "github.com";
              user = "git";
              identityFile = config.sops.secrets."ssh-private-keys/alan-laptop-nixos".path;
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
        trayscale.enable = true;
        vscode.enable = true;
      };
    };

    alanix.desktop = {
      enable = true;
      createHeadlessOutput = false;
      swayOutputRules = [ ];
      idle = {
        lockSeconds = 300;
        displayOffSeconds = 330;
        suspendSeconds = null;
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
      openFirewallOnWireguard = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJx7XE3EZOH49dap2q3IVLRjvf/Zb052puyJPjr+LBOM";
    };

    alanix.ddns = {
      enable = true;
      provider = "cloudflare";
      domains = [ "alan-laptop-nixos-wg.fifefin.com" ];
      credentialsFile = config.sops.templates."cloudflare-env".path;
    };

    alanix.wireguard = {
      enable = true;
      vpnIP = "10.100.0.4";
      endpoint = "alan-laptop-nixos-wg.fifefin.com:51820";
      publicKey = "U96LblYX6Klccf6yFVmKDQZp4882rSPTWq2wzFmbVV4=";
      privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
      listenPort = 51820;
      peers = [
        "alan-big-nixos"
        "randy-big-nixos"
        "alan-framework"
        "alan-framework-laptop"
        "alan-node"
      ];
    };

    alanix.tor = {
      enable = true;
      socksPort = 9050;
    };

    alanix.tailscale = {
      enable = true;
      acceptRoutes = true;
      operator = "buddia";
    };

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
