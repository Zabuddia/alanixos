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
      assist = {
        enable = true;
        customSentences.intents.HassTurnOn.data = [
          {
            sentences = [
              "(open|launch|start|run) [the] cody [app]"
            ];
            slots.name = "alan-tv Launch Kodi";
          }
        ];
      };
      openclawConversation.enable = true;
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
        "lichess"
        "litellm"
        "local_calendar"
        "local_todo"
        "luci"
        "met"
        "mcp_server"
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
        lovelace.dashboards.nixos-lovelace = lib.mkForce {
          filename = "ui-lovelace.yaml";
          icon = "mdi:home-assistant";
          mode = "yaml";
          show_in_sidebar = true;
          title = "Jarvis Home";
        };
      };

      lovelaceConfig = {
        title = "Home";
        views = [
          {
            title = "Home";
            path = "home";
            icon = "mdi:home";
            cards = [
              {
                type = "weather-forecast";
                entity = "weather.forecast_home";
                show_current = true;
                show_forecast = true;
                forecast_type = "daily";
              }
              {
                type = "calendar";
                title = "Calendar";
                initial_view = "listWeek";
                entities = [
                  "calendar.alancalendar"
                  "calendar.united_states_tx"
                ];
              }
              {
                type = "todo-list";
                title = "Shopping List";
                entity = "todo.shopping_list";
              }
              {
                type = "todo-list";
                title = "To-do List";
                entity = "todo.to_do_list";
              }
              {
                type = "entities";
                title = "At a glance";
                show_header_toggle = false;
                entities = [
                  "sensor.date_time"
                  "sensor.pixel_fold_battery_level"
                  "sensor.system_monitor_battery"
                  "sensor.uptime"
                ];
              }
            ];
          }
          {
            title = "TV";
            path = "tv";
            icon = "mdi:television";
            cards = [
              {
                type = "media-control";
                entity = "media_player.alan_tv";
                name = "alan-tv Kodi";
              }
              {
                type = "entities";
                title = "Control alan-tv";
                show_header_toggle = false;
                entities = [
                  "button.wake_on_lan_a0_ad_9f_87_68_4e"
                  "select.alan_tv_application"
                  "text.alan_tv_type_text"
                  "script.close_alan_tv_application"
                ];
              }
              {
                type = "grid";
                title = "Applications";
                columns = 4;
                square = false;
                cards = map
                  (entity: {
                    type = "button";
                    inherit entity;
                    tap_action = {
                      action = "call-service";
                      service = "button.press";
                      target.entity_id = entity;
                    };
                  })
                  [
                    "button.alan_tv_launch_kodi"
                    "button.alan_tv_launch_steam"
                    "button.alan_tv_launch_dolphin"
                    "button.alan_tv_launch_eden"
                    "button.alan_tv_launch_heroic"
                    "button.alan_tv_launch_retroarch"
                    "button.alan_tv_launch_ryubing"
                    "button.alan_tv_close_current_app"
                  ];
              }
            ];
          }
          {
            title = "Network";
            path = "network";
            icon = "mdi:network";
            cards = [
              {
                type = "entities";
                title = "AdGuard Home";
                show_header_toggle = false;
                entities = [
                  "switch.adguard_home_protection"
                  "switch.adguard_home_filtering"
                  "switch.adguard_home_safe_browsing"
                  "switch.adguard_home_safe_search"
                  "switch.adguard_home_parental_control"
                  "switch.adguard_home_query_log"
                ];
              }
              {
                type = "entities";
                title = "DNS activity";
                show_header_toggle = false;
                entities = [
                  "sensor.adguard_home_dns_queries"
                  "sensor.adguard_home_dns_queries_blocked"
                  "sensor.adguard_home_dns_queries_blocked_ratio"
                  "sensor.adguard_home_average_processing_speed"
                ];
              }
            ];
          }
          {
            title = "Chess";
            path = "chess";
            icon = "mdi:chess-knight";
            cards = [
              {
                type = "entities";
                title = "Chess.com";
                show_header_toggle = false;
                entities = [
                  "sensor.buddia_bullet_chess_rating"
                  "sensor.buddia_blitz_chess_rating"
                  "sensor.buddia_rapid_chess_rating"
                ];
              }
              {
                type = "entities";
                title = "Lichess";
                show_header_toggle = false;
                entities = [
                  "sensor.buddia_bullet_rating"
                  "sensor.buddia_blitz_rating"
                  "sensor.buddia_rapid_rating"
                  "sensor.buddia_classical_rating"
                ];
              }
            ];
          }
          {
            title = "System";
            path = "system";
            icon = "mdi:server";
            cards = [
              {
                type = "entities";
                title = "alan-home";
                show_header_toggle = false;
                entities = [
                  "sensor.system_monitor_battery"
                  "binary_sensor.system_monitor_charging"
                  "sensor.uptime"
                  "sensor.home_assistant_version_current_version"
                ];
              }
              {
                type = "entities";
                title = "Voice Assistant";
                show_header_toggle = false;
                entities = [
                  "select.home_assistant_voice_0a946b_assistant"
                  "select.home_assistant_voice_0a946b_wake_word"
                  "select.home_assistant_voice_0a946b_wake_word_sensitivity"
                  "switch.home_assistant_voice_0a946b_mute"
                  "switch.home_assistant_voice_0a946b_wake_sound"
                ];
              }
              {
                type = "entities";
                title = "Pixel Fold";
                show_header_toggle = false;
                entities = [
                  "sensor.pixel_fold_battery_level"
                  "sensor.pixel_fold_battery_state"
                  "sensor.pixel_fold_charger_type"
                  "device_tracker.pixel_fold"
                ];
              }
            ];
          }
        ];
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
