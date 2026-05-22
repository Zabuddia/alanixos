{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, pkgs, pkgs-unstable, ... }: {
    imports = [
      ./hardware-configuration.nix
      ./secrets.nix
      ../../clusters/home.nix
      # ../../modules/services/bitcoin.nix
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
        iotop
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

        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAJK6Bk63YjxmL9CI3F5yCjhG3MPAuuplydZ5ZmPFzW fife.alan@protonmail.com";
        authorizedHosts = [ "alan-framework" "alan-framework-laptop" "alan-laptop-nixos" "alan-node" "alan-optiplex" "randy-big-nixos" ];

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

        azahar.enable = true;
        desktop = {
          enable = true;
          profile = "sway/default";
        };
        chromium.enable = true;
        dolphin.enable = true;
        melonds.enable = true;
        ryubing.enable = true;
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

    alanix.ssh = {
      enable = true;
      openFirewallOnWireguard = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEOwubCYI6sBZbrhRLFMuV8IpReT40dcZ6qLBarejXxS";
    };

    alanix.ddns = {
      enable = true;
      provider = "cloudflare";
      domains = [ "alan-big-nixos-wg.fifefin.com" ];
      credentialsFile = config.sops.templates."cloudflare-env".path;
    };

    alanix.wireguard = {
      enable = true;
      vpnIP = "10.100.0.1";
      endpoint = "alan-big-nixos-wg.fifefin.com:51820";
      publicKey = "19Kloz2N3r2ksivuyLNtSplbDxS1kneNzVNRFhnQoCA=";
      privateKeyFile = config.sops.secrets."wireguard-private-keys/${hostname}".path;
      listenPort = 51820;
      peers = [
        "randy-big-nixos"
        "alan-framework"
        "alan-framework-laptop"
        "alan-laptop-nixos"
        "alan-node"
        "alan-optiplex"
      ];
    };

    alanix.tailscale = {
      enable = true;
      address = "alan-big-nixos";
      acceptRoutes = true;
      operator = "buddia";
    };

    alanix.wifi.radio.enable = false;

    alanix.syncthing = {
      deviceId = "5CVWFSK-CV4SWJP-Z7S4TTV-UAX263E-AEEWI6K-Z22GRUZ-F2JFFQY-LOZWLAS";
      peers = [
        "alan-node"
        "alan-optiplex"
        "alan-framework"
        "alan-framework-laptop"
        "randy-big-nixos"
      ];
      folderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "emulation-ryujinx"
      ];
      linkFolderSets = [
        "emulation-azahar"
        "emulation-dolphin"
        "emulation-melonds"
        "emulation-ryujinx"
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

    alanix.tvheadend = {
      enable = true;
      recordingsDir = "/srv/tvheadend/recordings";
      expose.tor = {
        enable = true;
        publicPort = 80;
        secretKeyBase64Secret = "tor/tvheadend/secret-key-base64";
      };
      expose.tailscale = {
        enable = true;
        port = 19981;
      };
      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 9981;
      };
      htsp.expose.tailscale = {
        enable = true;
        port = 19982;
      };
      htsp.expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 9982;
      };
    };

    alanix.openwebrx = {
      enable = true;
      users.buddia.passwordSecret = "openwebrx-passwords/buddia";

      rtlSdr = {
        name = "RTL-SDR Blog";
        device = "0";

        profiles = {
          am_broadcast = {
            name = "AM Broadcast 0.53-1.71 MHz";
            centerFreq = 1100000;
            sampleRate = 2048000;
            startFreq = 850000;
            startMod = "am";
            rfGain = "auto";
          };

          weather = {
            name = "NOAA Weather";
            centerFreq = 162400000;
            sampleRate = 1024000;
            startFreq = 162550000;
            startMod = "nfm";
          };

          two_meter = {
            name = "2m Calling";
            centerFreq = 146500000;
            sampleRate = 2048000;
            startFreq = 146520000;
            startMod = "nfm";
          };

          seventy_centimeter = {
            name = "70cm Calling";
            centerFreq = 446000000;
            sampleRate = 2048000;
            startFreq = 446000000;
            startMod = "nfm";
          };

          fm_band_1 = {
            name = "FM 88.0-90.6";
            centerFreq = 89280000;
            sampleRate = 2560000;
            startFreq = 89500000;
            startMod = "wfm";
            rfGain = "auto";
          };

          fm_band_2 = {
            name = "FM 90.6-93.1";
            centerFreq = 91840000;
            sampleRate = 2560000;
            startFreq = 91700000;
            startMod = "wfm";
            rfGain = "auto";
          };

          fm_band_3 = {
            name = "FM 93.1-95.7";
            centerFreq = 94400000;
            sampleRate = 2560000;
            startFreq = 94500000;
            startMod = "wfm";
            rfGain = "auto";
          };

          fm_band_4 = {
            name = "FM 95.7-98.2";
            centerFreq = 96960000;
            sampleRate = 2560000;
            startFreq = 97000000;
            startMod = "wfm";
            rfGain = "auto";
          };

          fm_band_5 = {
            name = "FM 98.2-100.8";
            centerFreq = 99520000;
            sampleRate = 2560000;
            startFreq = 99700000;
            startMod = "wfm";
            rfGain = "auto";
          };

          fm_band_6 = {
            name = "FM 100.8-103.4";
            centerFreq = 102080000;
            sampleRate = 2560000;
            startFreq = 101900000;
            startMod = "wfm";
            rfGain = "auto";
          };

          fm_band_7 = {
            name = "FM 103.4-105.9";
            centerFreq = 104640000;
            sampleRate = 2560000;
            startFreq = 104700000;
            startMod = "wfm";
            rfGain = "auto";
          };

          fm_band_8 = {
            name = "FM 105.9-108.5";
            centerFreq = 107200000;
            sampleRate = 2560000;
            startFreq = 106700000;
            startMod = "wfm";
            rfGain = "auto";
          };
        };
      };

      expose.tailscale = {
        enable = true;
        port = 18073;
      };

      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 18074;
      };
    };

    alanix.icecast = {
      enable = true;
      admin.user = "buddia";
      admin.passwordSecret = "icecast-passwords/buddia";
      source.passwordSecret = "icecast-passwords/buddia";

      expose.tailscale = {
        enable = true;
        port = 18075;
      };

      expose.wireguard = {
        enable = true;
        address = "10.100.0.1";
        port = 18076;
      };
    };

    alanix.radioStreams = {
      enable = true;
      device = "0";
      defaultStation = "fm_94_9";
      liveMount = "/live.mp3";

      stations =
        let
          mkFm = frequency: name: genre: {
            inherit frequency name genre;
            description = "Off-air Provo FM preset: ${name}";
            mode = "wbfm";
            bitrate = 160;
          };
          mkFmWith = frequency: name: genre: attrs:
            mkFm frequency name genre // attrs;
        in
        {
          fm_88_1 = mkFm 88100000 "88.1 KPGR" "Variety";
          fm_88_3 = mkFm 88300000 "88.3 K202CC CSN Radio" "Christian";
          fm_88_7 = mkFm 88700000 "88.7 K204BO Utah Public Radio" "Public Radio";
          fm_89_1 = mkFm 89100000 "89.1 KBYU Classical 89" "Classical";
          fm_89_5 = mkFm 89500000 "89.5 K208BZ Classical 89" "Classical";
          fm_90_1 = mkFm 90100000 "90.1 KUER Public Radio" "Public Radio";
          fm_90_9 = mkFm 90900000 "90.9 KRCL Community Radio" "Variety";
          fm_91_3 = mkFm 91300000 "91.3 K217CL Key Radio" "Religious";
          fm_91_7 = mkFm 91700000 "91.7 KOHS" "Variety";
          fm_92_1 = mkFm 92100000 "92.1 KTCE The Touch" "Hot AC";
          fm_92_5 = mkFm 92500000 "92.5 KUUU The Beat" "Rhythmic CHR";
          fm_92_9 = mkFm 92900000 "92.9 KPUT La Mejor" "Regional Mexican";
          fm_93_3 = mkFm 93300000 "93.3 KUBL The Bull" "Country";
          fm_93_7 = mkFm 93700000 "93.7 KKUT The Wolf" "Country";
          fm_94_1 = mkFm 94100000 "94.1 KODJ" "Classic Hits";
          fm_94_5 = mkFmWith 94500000 "94.5 K233DI ESPN 960" "Sports" {
            gain = 14.4;
            sampleRate = 170000;
            audioLowPass = 12000;
          };
          fm_94_9 = mkFm 94900000 "94.9 KENZ Power 94.9/101.9" "Top 40";
          fm_95_3 = mkFm 95300000 "95.3 K237FG The Truth" "Religious Talk";
          fm_96_3 = mkFm 96300000 "96.3 KXRK X96" "Alternative";
          fm_96_7 = mkFm 96700000 "96.7 KUTN Flashback 96.7" "Classic Hits";
          fm_97_1 = mkFm 97100000 "97.1 KZHT 97.1 ZHT" "Top 40";
          fm_97_5 = mkFm 97500000 "97.5 KZNS KSL Sports Zone" "Sports";
          fm_97_9 = mkFm 97900000 "97.9 KBZN Now 97.9" "Hot AC";
          fm_98_3 = mkFm 98300000 "98.3 K252DB The Wolf" "Country";
          fm_98_7 = mkFm 98700000 "98.7 KBEE B98.7" "Adult Contemporary";
          fm_99_5 = mkFm 99500000 "99.5 KJMY My 99.5" "Hot AC";
          fm_99_9 = mkFm 99900000 "99.9 K260DS Tu Familia Radio" "Spanish Religious";
          fm_100_3 = mkFm 100300000 "100.3 KSFI FM100" "Adult Contemporary";
          fm_100_7 = mkFm 100700000 "100.7 KYMV Bob 100.7/105.5" "Variety Hits";
          fm_101_1 = mkFm 101100000 "101.1 KBER Utah's Rock Station" "Rock";
          fm_101_5 = mkFm 101500000 "101.5 KNAH Hank FM" "Country";
          fm_101_9 = mkFm 101900000 "101.9 KHTB Power 94.9/101.9" "Top 40";
          fm_102_3 = mkFm 102300000 "102.3 KDUT La GranD" "Regional Mexican";
          fm_102_7 = mkFm 102700000 "102.7 KSL NewsRadio" "News/Talk";
          fm_103_1 = mkFm 103100000 "103.1 KLO Coast 103" "Talk";
          fm_103_5 = mkFm 103500000 "103.5 KRSP The Arrow" "Classic Hits";
          fm_103_9 = mkFm 103900000 "103.9 K280GJ Mix 105.1" "Top 40";
          fm_104_3 = mkFm 104300000 "104.3 KSOP Z104" "Country";
          fm_104_7 = mkFm 104700000 "104.7 KNIV Mi Preferida" "Regional Mexican";
          fm_105_1 = mkFm 105100000 "105.1 KUDD Mix 105.1" "Top 40";
          fm_105_9 = mkFm 105900000 "105.9 KNRS Talk Radio" "News/Talk";
          fm_106_3 = mkFm 106300000 "106.3 KBMG Latino 106.3" "Spanish";
          fm_106_7 = mkFm 106700000 "106.7 KAAZ Rock 106.7" "Classic Rock";
          fm_107_1 = mkFm 107100000 "107.1 KEGH La Ley" "Regional Mexican";
          fm_107_5 = mkFm 107500000 "107.5 KKLV K-Love" "Christian Contemporary";
          fm_107_9 = mkFm 107900000 "107.9 KUMT BYUradio" "Public Radio";

          weather = {
            name = "NOAA Weather 162.550";
            description = "NOAA Weather Radio on 162.550 MHz";
            genre = "Weather";
            frequency = 162550000;
            mode = "nfm";
            bitrate = 64;
          };
        };
    };

    alanix.remote-desktop = {
      enable = true;
      autoStart = true;
      port = 5900;
      output = "HEADLESS-1";
    };

    alanix.sunshine = {
      enable = true;
      autoStart = true;
      openFirewall = true;
      capSysAdmin = true;
      webUi = {
        port = 47990;
        username = "buddia";
        passwordFile = config.sops.secrets."sunshine-web-ui-passwords/alan-big-nixos".path;
      };
    };
  };
}
