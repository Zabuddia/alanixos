{ config, lib, name, nixosConfig, pkgs, pkgs-unstable, ... }:

let
  cfg = config.desktop;
  idleCfg = nixosConfig.alanix.desktop.idle;
  terminalEmulator = lib.getExe pkgs-unstable.foot;
  powerProfileMenuFile = "${config.home.directory}/.config/waybar/power-profile-menu.xml";
  volumeFeedbackWav = pkgs.runCommand "alanix-volume-feedback.wav" { } ''
    ${pkgs.ffmpeg}/bin/ffmpeg -loglevel error \
      -f lavfi -i "sine=frequency=1046.5:duration=0.05" \
      -filter:a "volume=0.15" \
      -ac 1 -ar 48000 -c:a pcm_s16le \
      -y "$out"
  '';
  volumeRaiseCommand = pkgs.writeShellScript "alanix-volume-raise" ''
    ${pkgs.swayosd}/bin/swayosd-client --output-volume raise
    ${pkgs.pulseaudio}/bin/paplay ${volumeFeedbackWav} >/dev/null 2>&1 &
  '';
  volumeLowerCommand = pkgs.writeShellScript "alanix-volume-lower" ''
    ${pkgs.swayosd}/bin/swayosd-client --output-volume lower
    ${pkgs.pulseaudio}/bin/paplay ${volumeFeedbackWav} >/dev/null 2>&1 &
  '';
  volumeMuteToggleCommand = pkgs.writeShellScript "alanix-volume-mute-toggle" ''
    exec ${pkgs.swayosd}/bin/swayosd-client --output-volume mute-toggle
  '';
  brightnessRaiseCommand = pkgs.writeShellScript "alanix-brightness-raise" ''
    exec ${pkgs.swayosd}/bin/swayosd-client --brightness +5
  '';
  brightnessLowerCommand = pkgs.writeShellScript "alanix-brightness-lower" ''
    exec ${pkgs.swayosd}/bin/swayosd-client --brightness -5
  '';
  setPowerProfileCommand =
    profile:
    "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${lib.escapeShellArg profile} && ${pkgs.procps}/bin/pkill -SIGUSR2 -x waybar";
  batteryModuleCommand = pkgs.writeShellScript "alanix-waybar-battery" ''
    set -eu

    batteryInfo="$(${pkgs.upower}/bin/upower -i /org/freedesktop/UPower/devices/DisplayDevice 2>/dev/null || true)"

    percentage="$(
      printf '%s\n' "$batteryInfo" \
        | ${pkgs.gnused}/bin/sed -n 's/^ *percentage: *\([0-9]\+\)%$/\1/p' \
        | ${pkgs.coreutils}/bin/head -n1
    )"
    state="$(
      printf '%s\n' "$batteryInfo" \
        | ${pkgs.gnused}/bin/sed -n 's/^ *state: *//p' \
        | ${pkgs.coreutils}/bin/head -n1
    )"
    timeLine="$(
      printf '%s\n' "$batteryInfo" \
        | ${pkgs.gnused}/bin/sed -n 's/^ *\(time to [^:]*\): *\(.*\)$/\1: \2/p' \
        | ${pkgs.coreutils}/bin/head -n1
    )"
    powerProfile="$(${pkgs.power-profiles-daemon}/bin/powerprofilesctl get 2>/dev/null || true)"

    if [ -z "$percentage" ]; then
      percentage=0
    fi

    case "$powerProfile" in
      power-saver) powerProfileLabel="Power saver" ;;
      balanced) powerProfileLabel="Normal" ;;
      performance) powerProfileLabel="Performance" ;;
      *) powerProfileLabel="Unknown" ;;
    esac

    if [ -z "$timeLine" ]; then
      case "$state" in
        fully-charged) timeLine="Fully charged" ;;
        charging | pending-charge) timeLine="Charging" ;;
        discharging | pending-discharge) timeLine="Calculating remaining time" ;;
        *) timeLine="State: ''${state:-unknown}" ;;
      esac
    fi

    icons=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
    iconIndex=$(( percentage * ''${#icons[@]} / 100 ))
    if [ "$iconIndex" -ge "''${#icons[@]}" ]; then
      iconIndex=$(( ''${#icons[@]} - 1 ))
    fi
    icon="''${icons[$iconIndex]}"

    case "$state" in
      charging | pending-charge)
        text="$percentage% ↑"
        statusClass="charging"
        ;;
      fully-charged)
        text="$percentage% ⚡"
        statusClass="charging"
        ;;
      *)
        text="$percentage% $icon"
        statusClass="discharging"
        ;;
    esac

    if [ "$percentage" -le 15 ]; then
      batteryClass="critical"
    elif [ "$percentage" -le 30 ]; then
      batteryClass="warning"
    else
      batteryClass="normal"
    fi

    tooltip="Battery: $percentage%
$timeLine
Power profile: $powerProfileLabel"

    ${pkgs.jq}/bin/jq -cn \
      --arg text "$text" \
      --arg tooltip "$tooltip" \
      --arg percentage "$percentage" \
      --arg batteryClass "$batteryClass" \
      --arg statusClass "$statusClass" \
      '{
        text: $text,
        tooltip: $tooltip,
        percentage: ($percentage | tonumber),
        class: [$batteryClass, $statusClass]
      }'
  '';
in
{
  options.desktop.enable = lib.mkEnableOption "desktop essentials for this user";

  config = {
    _assertions = lib.optionals cfg.enable [
      {
        assertion = nixosConfig.alanix.desktop.enable;
        message = "alanix.users.accounts.${name}.desktop.enable requires alanix.desktop.enable = true.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        home.file."Pictures/.keep".text = "";

        xdg.configFile."xfce4/helpers.rc".text = ''
          TerminalEmulator=${terminalEmulator}
        '';

        xdg.configFile."waybar/power-profile-menu.xml".text = ''
          <?xml version="1.0" encoding="UTF-8"?>
          <interface>
            <object class="GtkMenu" id="menu">
              <child>
                <object class="GtkMenuItem" id="power_saver">
                  <property name="label">Power saver</property>
                </object>
              </child>
              <child>
                <object class="GtkMenuItem" id="normal">
                  <property name="label">Normal</property>
                </object>
              </child>
              <child>
                <object class="GtkMenuItem" id="performance">
                  <property name="label">Performance</property>
                </object>
              </child>
            </object>
          </interface>
        '';

        home.packages =
          (with pkgs; [
            adwaita-icon-theme
            pulseaudio
            swaylock
            swayosd
            brightnessctl
            grim
            hicolor-icon-theme
            slurp
            nnn
            imv
            wl-clipboard
          ])
          ++ (with pkgs-unstable; [ wofi ]);

        gtk = {
          enable = true;
          iconTheme = {
            name = "Adwaita";
            package = pkgs.adwaita-icon-theme;
          };
        };

        xsession.preferStatusNotifierItems = true;

        xfconf.settings = {
          xfce4-session = {
            "compat/LaunchGNOME" = true;
          };
        };

        programs.foot = {
          enable = true;
          package = pkgs-unstable.foot;
        };

        services.mako = {
          enable = true;
          settings.default-timeout = 5000;
        };

        services.lxqt-policykit-agent.enable = true;

        services.udiskie = {
          enable = true;
          automount = true;
          notify = true;
          tray = "auto";
        };

        systemd.user.services.swayosd-server = {
          Unit = {
            Description = "SwayOSD server";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${pkgs.swayosd}/bin/swayosd-server";
            Restart = "always";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        programs.wlogout = {
          enable = true;
          layout = [
            { label = "lock"; action = "${pkgs.swaylock}/bin/swaylock -f"; text = "Lock"; keybind = "l"; }
            { label = "logout"; action = "loginctl terminate-user $USER"; text = "Logout"; keybind = "e"; }
            { label = "suspend"; action = "systemctl suspend"; text = "Suspend"; keybind = "u"; }
            { label = "shutdown"; action = "systemctl poweroff"; text = "Shutdown"; keybind = "s"; }
            { label = "reboot"; action = "systemctl reboot"; text = "Reboot"; keybind = "r"; }
          ];
        };

        services.swayidle = {
          enable = true;
          events = [
            { event = "before-sleep"; command = "${pkgs.swaylock}/bin/swaylock -f"; }
            { event = "lock"; command = "${pkgs.swaylock}/bin/swaylock -f"; }
          ];
          timeouts =
            lib.optionals (idleCfg.lockSeconds != null) [
              {
                timeout = idleCfg.lockSeconds;
                command = "${pkgs.swaylock}/bin/swaylock -f";
              }
            ]
            ++ lib.optionals (idleCfg.displayOffSeconds != null) [
              {
                timeout = idleCfg.displayOffSeconds;
                command = "${pkgs.sway}/bin/swaymsg 'output * power off'";
                resumeCommand = "${pkgs.sway}/bin/swaymsg 'output * power on'";
              }
            ]
            ++ lib.optionals (idleCfg.suspendSeconds != null) [
              {
                timeout = idleCfg.suspendSeconds;
                command = "systemctl suspend";
              }
            ];
        };

        programs.waybar = {
          enable = true;
          package = pkgs-unstable.waybar;
          settings = [{
            layer = "top";
            position = "top";
            height = 32;
            modules-left = [ "sway/workspaces" "sway/mode" ];
            modules-center = [ "clock" ];
            modules-right = [ "cpu" "memory" "network" "pulseaudio" "backlight" "custom/battery" "tray" "custom/logout" ];

            "sway/workspaces".all-outputs = false;

            "clock" = {
              format = "{:%a %d %b  %H:%M}";
              tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
            };

            "cpu" = {
              format = "CPU {usage}%";
              interval = 5;
            };

            "memory" = {
              format = "RAM {percentage}%";
              tooltip-format = "{used:0.1f}G / {total:0.1f}G";
            };

            "network" = {
              format-wifi = "{essid} {signalStrength}%";
              format-ethernet = "ETH ↑{bandwidthUpBytes} ↓{bandwidthDownBytes}";
              format-disconnected = "disconnected";
              tooltip-format-wifi = "{ipaddr} ({signalStrength}%)";
              tooltip-format-ethernet = "{ifname}: {ipaddr}";
              interval = 5;
            };

            "pulseaudio" = {
              format = "VOL {volume}%";
              format-muted = "MUTED";
              on-scroll-up = "${volumeRaiseCommand}";
              on-scroll-down = "${volumeLowerCommand}";
              on-click = "${volumeMuteToggleCommand}";
            };

            "backlight" = {
              device = "amdgpu_bl1";
              format = "BRT {percent}%";
              on-scroll-up = "${brightnessRaiseCommand}";
              on-scroll-down = "${brightnessLowerCommand}";
            };

            "custom/battery" = {
              format = "{text}";
              return-type = "json";
              interval = 5;
              exec = "${batteryModuleCommand}";
              menu = "on-click";
              menu-file = powerProfileMenuFile;
              menu-actions = {
                power_saver = setPowerProfileCommand "power-saver";
                normal = setPowerProfileCommand "balanced";
                performance = setPowerProfileCommand "performance";
              };
            };

            "tray" = {
              icon-size = 16;
              spacing = 8;
            };

            "custom/logout" = {
              format = "⏻";
              on-click = "wlogout";
              tooltip = false;
            };
          }];

          style = ''
            * {
              border: none;
              border-radius: 0;
              font-family: monospace;
              font-size: 13px;
              min-height: 0;
            }

            window#waybar {
              background: rgba(20, 20, 20, 0.95);
              color: #cdd6f4;
            }

            #workspaces button {
              padding: 0 8px;
              color: #585b70;
              background: transparent;
            }

            #workspaces button.focused {
              color: #cdd6f4;
            }

            #workspaces button:hover {
              background: rgba(255, 255, 255, 0.05);
            }

            #clock,
            #cpu,
            #memory,
            #network,
            #pulseaudio,
            #backlight,
            #custom-battery,
            #tray,
            #custom-logout {
              padding: 0 12px;
              color: #cdd6f4;
              background: transparent;
            }

            #custom-battery.warning {
              color: #fab387;
            }

            #custom-battery.critical:not(.charging) {
              color: #f38ba8;
            }

            #network.disconnected {
              color: #f38ba8;
            }
          '';
        };

        wayland.windowManager.sway = {
          enable = true;
          extraConfigEarly = ''
            include /etc/sway/config.d/*
          '';
          config = {
            modifier = "Mod4";
            terminal = terminalEmulator;
            bars = [ ];
            startup = [
              { command = "waybar"; }
              { command = "blueman-applet"; }
              { command = "sleep 2 && swaymsg workspace number 1"; always = false; }
            ];
            keybindings = lib.mkOptionDefault {
              "XF86AudioRaiseVolume" = "exec ${volumeRaiseCommand}";
              "XF86AudioLowerVolume" = "exec ${volumeLowerCommand}";
              "XF86AudioMute" = "exec ${volumeMuteToggleCommand}";
              "XF86MonBrightnessUp" = "exec ${brightnessRaiseCommand}";
              "XF86MonBrightnessDown" = "exec ${brightnessLowerCommand}";
              "Mod4+Shift+e" = "exec wlogout";
              "Print" = "exec sh -c 'grim - | tee ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png | wl-copy'";
              "Shift+Print" = "exec sh -c 'grim -g \"$(slurp)\" - | tee ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png | wl-copy'";
            };
            input."type:touchpad" = {
              tap = "enabled";
              click_method = "clickfinger";
              dwt = "enabled";
              natural_scroll = "enabled";
            };
          };
          extraConfig = ''
            bindgesture swipe:3:left workspace next
            bindgesture swipe:3:right workspace prev
          '';
        };
      }
    ];
  };
}
