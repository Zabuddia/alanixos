{ hostname, ... }:

{
  system = "x86_64-linux";

  module = { config, lib, pkgs, pkgs-unstable, inputs, ... }:
  let
    lidBacklight = pkgs.writeShellScript "alan-home-lid-backlight" ''
      set -eu

      stateFile="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/alan-home-lid-backlight"

      case "$1" in
        close)
          current="$(${pkgs.brightnessctl}/bin/brightnessctl -d acpi_video0 get)"
          if [ "$current" -gt 0 ]; then
            printf '%s\n' "$current" > "$stateFile"
          fi
          exec ${pkgs.brightnessctl}/bin/brightnessctl -q -n 0 -d acpi_video0 set 0
          ;;
        open)
          if [ -r "$stateFile" ]; then
            IFS= read -r previous < "$stateFile"
            ${pkgs.coreutils}/bin/rm -f "$stateFile"
            exec ${pkgs.brightnessctl}/bin/brightnessctl -q -n 0 -d acpi_video0 set "$previous"
          fi
          ;;
        *)
          exit 2
          ;;
      esac
    '';
  in
  {
    imports = [
      (inputs.nixpkgs-unstable + "/nixos/modules/services/home-automation/home-assistant.nix")
      ./hardware-configuration.nix
      ./secrets.nix
    ];

    disabledModules = [ "services/home-automation/home-assistant.nix" ];

    # The 2013 MacBook Air's Broadcom adapter needs the proprietary wl driver.
    # broadcom_sta is intentionally allowlisted despite its known security
    # issues because no supported in-kernel driver works for this hardware.
    nixpkgs.config.permittedInsecurePackages = [
      (config.boot.kernelPackages.broadcom_sta).name
    ];
    hardware.enableRedistributableFirmware = true;
    boot = {
      extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];
      kernelModules = [ "wl" ];
      blacklistedKernelModules = [
        "b43"
        "bcma"
        "ssb"
        "brcmsmac"
        "brcmfmac"
      ];

      # This is also used by the upstream nixos-hardware MacBookAir6 profile
      # to avoid unusually high idle power consumption on this model.
      kernelParams = [ "acpi_osi=" ];
    };

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
        bind
        curl
        dosfstools
        git
        htop
        iotop
        jq
        lm_sensors
        lsof
        parted
        pciutils
        p7zip
        python3
        restic
        ripgrep
        sops
        tree
        unzip
        usbutils
        wget
        zip
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
        passwordlessSudo = true;
        extraGroups = [ "wheel" "networkmanager" "input" "video" ];
        hashedPasswordFile = config.sops.secrets."password-hashes/buddia".path;
        sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBfgSBeGut2uhEHxAXd0bxErTV0pPoJ9Z2t5/c/+08fy fife.alan@protonmail.com";
        authorizedHosts = [
          "alan-big-nixos"
          "alan-framework"
          "alan-framework-laptop"
          "alan-node"
          "alan-optiplex"
          "alan-tv"
          "fife-tv"
          "randy-big-nixos"
        ];

        home = {
          enable = true;
          directory = "/home/buddia";
          stateVersion = "26.05";
          files = { };
          packages = with pkgs; [
            tmux
          ];
          unstablePackages = [ ];
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
        chromium.enable = true;
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
        createHeadlessOutput = false;
        outputRules = [
          "bindswitch --reload lid:on exec ${lidBacklight} close"
          "bindswitch --reload lid:off exec ${lidBacklight} open"
        ];
        idle = {
          lockSeconds = null;
          displayOffSeconds = null;
          suspendSeconds = null;
        };
      };
    };

    alanix.power = {
      enable = true;
      enablePowerProfilesDaemon = false;
      enableUpower = true;
      enableThermald = true;
      enablePowertop = false;
      lidSwitch = {
        enable = true;
        action = "ignore";
        externalPowerAction = "ignore";
        dockedAction = "ignore";
      };
      hibernate.enable = false;
    };

    # Treat the laptop as an always-on server: applications and users cannot
    # accidentally suspend or hibernate it, including while the lid is closed.
    systemd.sleep.settings.Sleep = {
      AllowSuspend = "no";
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
    };
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
    };

    # Keep the older Apple hardware cool during closed-lid, continuous use.
    services.mbpfan.enable = true;

    # default_config includes Home Assistant's Bluetooth integration. Start
    # BlueZ so the built-in adapter is available for local BLE devices.
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    alanix.ssh = {
      enable = true;
      openFirewallOnTailscale = true;
      startAgent = true;
      hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL4iIcmZmIqi6c/kWTzWgAMEo1p0tXkbCSp968snZ+ME root@alan-home";
    };

    alanix.tailscale = {
      enable = true;
      loginServer = "https://headscale.fifefin.com";
      address = hostname;
      acceptRoutes = false;
      operator = "buddia";
    };

    alanix.wifi = {
      radio.enable = true;
      networks = [ ];
    };
    networking = {
      interfaces.wlp3s0.useDHCP = true;
      networkmanager.unmanaged = [ "interface-name:wlp3s0" ];
      wireless = {
        enable = true;
        interfaces = [ "wlp3s0" ];
        autoDetectInterfaces = false;
        dbusControlled = lib.mkForce false;
        driver = "wext";
        scanOnLowSignal = false;
        secretsFile = config.sops.templates."alan-home-wpa-supplicant-secrets".path;
        networks.OpenWrt.pskRaw = "ext:openwrt_psk";
      };
    };

    sops.templates."alan-home-wpa-supplicant-secrets" = {
      content = "openwrt_psk=${config.sops.placeholder."wifi-passwords/OpenWrt"}\n";
      owner = "wpa_supplicant";
      group = "wpa_supplicant";
      mode = "0400";
    };

    systemd.services.wpa_supplicant-wlp3s0.serviceConfig.BindReadOnlyPaths = [
      config.sops.templates."alan-home-wpa-supplicant-secrets".path
    ];

    # Advertise and discover local smart-home services over mDNS.
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    alanix.home-assistant = {
      enable = true;
      package = pkgs-unstable.home-assistant;
      name = "Home";
      unitSystem = "us_customary";
      openFirewall = true;
      extraComponents = [
        "adguard"
        "bluetooth"
        "caldav"
        "chess_com"
        "default_config"
        "esphome"
        "github"
        "holiday"
        "immich"
        "improv_ble"
        "kodi"
        "jellyfin"
        "lichess"
        "litellm"
        "local_calendar"
        "local_todo"
        "luci"
        "met"
        "mqtt"
        "owntracks"
        "piper"
        "remote_calendar"
        "syncthing"
        "systemmonitor"
        "tailscale"
        "time_date"
        "ubus"
        "uptime"
        "version"
        "wake_on_lan"
        "worldclock"
        "wyoming"
      ];
      config = {
        homeassistant.internal_url = "http://192.168.10.212:8123";

        script = {
          launch_alan_tv_application = {
            alias = "Launch an application on alan-tv";
            description = ''
              Launch an installed application on the alan-tv media PC. Pass
              the application's display name, such as Kodi, Dolphin, Steam,
              Heroic, Eden, Ryubing, or RetroArch.
            '';
            fields.application = {
              name = "Application";
              description = "Display name of the application to launch.";
              required = true;
              selector.text = { };
            };
            sequence = [
              {
                action = "select.select_option";
                target.entity_id = "select.alan_tv_application";
                data.option = "{{ application }}";
              }
            ];
          };

          close_alan_tv_application = {
            alias = "Close the current application on alan-tv";
            description = ''
              Close the application window currently focused on the alan-tv
              media PC. Use this when asked to close, quit, or exit the current
              TV application.
            '';
            sequence = [
              {
                action = "button.press";
                target.entity_id = "button.alan_tv_close_current_app";
              }
            ];
          };
        };
      };
    };

    services.mosquitto = {
      enable = true;
      listeners = [
        {
          port = 1883;
          acl = [ "topic readwrite #" ];
          settings.allow_anonymous = true;
        }
      ];
    };

    networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 1883 ];

    alanix.remote-desktop = {
      enable = true;
      autoStart = true;
      port = 5900;
      output = "eDP-1";
    };
  };
}
