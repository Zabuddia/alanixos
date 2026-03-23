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
        restic
        sops
        tree
        wget
        vlc
        ffmpeg
        w_scan2
        nano
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

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "25.11";
          files = {
            ".ssh/id_ed25519.pub" = {
              text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNJ7KX0IIt27KqD2c3dqMT8vbO0K/G1ibfC+a/WxijO fife.alan@protonmail.com";
              source = null;
              force = true;
              executable = null;
            };

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
          ];
          unstablePackages = with pkgs-unstable; [
            yt-dlp
            gimp
            firefox
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

        ssh = {
          enable = true;
          matchBlocks = {
            "github-personal" = {
              hostname = "github.com";
              user = "git";
              identityFile = "~/.ssh/id_ed25519";
              identitiesOnly = true;
              controlPath = "none";
            };

            "github-work" = {
              hostname = "github.com";
              user = "git";
              identityFile = "~/.ssh/id_ed25519_work";
              identitiesOnly = true;
              controlPath = "none";
            };
          };
        };

        desktop.enable = true;
        chromium.enable = true;
        librewolf.enable = true;
        nextcloudClient.enable = true;
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
        suspendSeconds = 1800;
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
      ];
    };

    alanix.tailscale = {
      enable = true;
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.openclaw = {
      user = "buddia";
      tokenSecret = "openclaw/gateway-token";

      browser = {
        enable = true;
        evaluateEnabled = true;
        headless = false;
        package = pkgs.chromium;
        executablePath = "${pkgs.chromium}/bin/chromium";
      };

      desktopNode = {
        enable = true;
        displayName = "alan-laptop-nixos";
        gatewayHost = "alan-framework.tailbb2802.ts.net";
        gatewayPort = 443;
        gatewayTls = true;
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
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-laptop-nixos".path;
      };
    };
  };
}
