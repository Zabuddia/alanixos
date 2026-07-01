{ config, lib, name, nixosConfig, pkgs, pkgs-unstable, ... }:

let
  inherit (lib) types;

  cfg = config.desktop;
  active = cfg.enable && cfg.profile == "sway/default";
  gameFocusCfg = cfg.sway.gameFocus;
  idleCfg = nixosConfig.alanix.desktop.profiles.sway.idle;
  terminalEmulator = lib.getExe pkgs-unstable.foot;
  powerProfileMenuFile = "${config.home.directory}/.config/waybar/power-profile-menu.xml";
  newlineShellList = values: lib.escapeShellArg (lib.concatStringsSep "\n" values);
  exactAppPatterns = map (app: "^${lib.escapeRegex app}$") gameFocusCfg.fullscreenApps;
  allFullscreenAppPatterns = gameFocusCfg.fullscreenAppPatterns ++ exactAppPatterns;
  fullscreenRuleLines =
    (map (pattern: ''for_window [app_id="${pattern}"] fullscreen enable, focus'') allFullscreenAppPatterns)
    ++ (map (pattern: ''for_window [class="${pattern}"] fullscreen enable, focus'') gameFocusCfg.fullscreenClassPatterns);
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
  gameFocusScript = pkgs.writeShellScript "alanix-sway-game-focus" ''
    set -u

    manage_cursor=${if gameFocusCfg.cursorHideMs == null then "0" else "1"}
    cursor_hide_ms=${if gameFocusCfg.cursorHideMs == null then "0" else toString gameFocusCfg.cursorHideMs}
    cursor_visible_app_patterns=${newlineShellList gameFocusCfg.cursorVisibleAppPatterns}
    fullscreen_apps=${newlineShellList gameFocusCfg.fullscreenApps}
    fullscreen_app_patterns=${newlineShellList gameFocusCfg.fullscreenAppPatterns}
    fullscreen_class_patterns=${newlineShellList gameFocusCfg.fullscreenClassPatterns}
    current_cursor_mode=""

    normalize_app_id() {
      printf '%s' "$1" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]'
    }

    contains_app() {
      [ -n "$1" ] && [ -n "$2" ] || return 1
      needle="$(normalize_app_id "$2")"
      while IFS= read -r configured_app; do
        configured_app="$(normalize_app_id "$configured_app")"
        [ -n "$configured_app" ] || continue
        if [ "$needle" = "$configured_app" ] || [ "''${needle##*.}" = "$configured_app" ]; then
          return 0
        fi
      done <<< "$1"
      return 1
    }

    matches_pattern() {
      [ -n "$1" ] && [ -n "$2" ] || return 1
      while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        if printf '%s' "$2" | ${pkgs.gnugrep}/bin/grep -Eq -- "$pattern"; then
          return 0
        fi
      done <<< "$1"
      return 1
    }

    focused_container() {
      ${pkgs.sway}/bin/swaymsg -t get_tree | ${pkgs.jq}/bin/jq -c '
        [
          .. | objects | select(.focused? == true) |
          {
            id: (.id // ""),
            app_id: (.app_id // .window_properties.class // ""),
            title: (.name // ""),
            fullscreen_mode: (.fullscreen_mode // 0)
          }
        ][0] // { id: "", app_id: "", title: "", fullscreen_mode: 0 }
      '
    }

    set_cursor_mode() {
      mode="$1"
      [ "$mode" != "$current_cursor_mode" ] || return 0

      if [ "$mode" = "visible" ]; then
        ${pkgs.sway}/bin/swaymsg 'seat * hide_cursor 0' >/dev/null || return 0
      else
        ${pkgs.sway}/bin/swaymsg "seat * hide_cursor $cursor_hide_ms" >/dev/null || return 0
      fi

      current_cursor_mode="$mode"
    }

    reconcile_focus() {
      change="$1"
      focused="$(focused_container 2>/dev/null || printf '%s\n' '{ "id": "", "app_id": "", "title": "", "fullscreen_mode": 0 }')"
      con_id="$(printf '%s' "$focused" | ${pkgs.jq}/bin/jq -r '.id // ""')"
      app_id="$(printf '%s' "$focused" | ${pkgs.jq}/bin/jq -r '.app_id // ""')"
      title="$(printf '%s' "$focused" | ${pkgs.jq}/bin/jq -r '.title // ""')"
      fullscreen_mode="$(printf '%s' "$focused" | ${pkgs.jq}/bin/jq -r '.fullscreen_mode // 0')"

      cursor_mode="unmanaged"
      if [ "$manage_cursor" = "1" ]; then
        cursor_mode="hide"
        if matches_pattern "$cursor_visible_app_patterns" "$app_id"; then
          cursor_mode="visible"
        fi
        set_cursor_mode "$cursor_mode"
      fi

      if { contains_app "$fullscreen_apps" "$app_id" \
        || matches_pattern "$fullscreen_app_patterns" "$app_id" \
        || matches_pattern "$fullscreen_class_patterns" "$app_id"; } \
        && [ "$fullscreen_mode" != "1" ] \
        && [ -n "$con_id" ]; then
        ${pkgs.sway}/bin/swaymsg "[con_id=$con_id] fullscreen enable" >/dev/null || true
      fi

      echo "change=$change focused_app=$app_id cursor_mode=$cursor_mode fullscreen_mode=$fullscreen_mode title=$title"
    }

    reconcile_focus startup

    while true; do
      while IFS= read -r event; do
        change="$(printf '%s' "$event" | ${pkgs.jq}/bin/jq -r '.change // ""')"
        reconcile_focus "$change"
      done < <(${pkgs.coreutils}/bin/timeout 10 ${pkgs.sway}/bin/swaymsg -t subscribe '["window"]')

      ${pkgs.coreutils}/bin/sleep 1
      reconcile_focus resubscribe
    done
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
  options.desktop.sway.gameFocus = {
    enable = lib.mkEnableOption "focus-aware Sway adjustments for controller-first game launchers";

    cursorHideMs = lib.mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Hide the Sway cursor after this many milliseconds except while focused app_ids match cursorVisibleAppPatterns.";
    };

    cursorVisibleAppPatterns = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extended regular expressions for app_ids that should disable Sway cursor hiding while focused.";
    };

    fullscreenApps = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Exact app_ids that should be forced fullscreen whenever focused.";
    };

    fullscreenAppPatterns = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extended regular expressions for app_ids that should be forced fullscreen.";
    };

    fullscreenClassPatterns = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extended regular expressions for XWayland classes that should be forced fullscreen.";
    };
  };

  config = {
    _assertions =
      lib.optionals (gameFocusCfg.enable && !active) [
        {
          assertion = false;
          message = "alanix.users.accounts.${name}.desktop.sway.gameFocus requires desktop.enable = true and desktop.profile = \"sway/default\".";
        }
      ]
      ++ lib.optionals active [
      {
        assertion = nixosConfig.alanix.desktop.profile == "sway";
        message = "alanix.users.accounts.${name}.desktop.profile = \"sway/default\" requires alanix.desktop.profile = \"sway\".";
      }
    ];

    home.modules = lib.optionals active [
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
            pavucontrol
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

        systemd.user.services.alanix-sway-game-focus = lib.mkIf gameFocusCfg.enable {
          Unit = {
            Description = "Focus-aware Sway tweaks for game launchers";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${gameFocusScript}";
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
          events = {
            before-sleep = "${pkgs.swaylock}/bin/swaylock -f";
            lock = "${pkgs.swaylock}/bin/swaylock -f";
          };
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
            menu = lib.mkDefault "${lib.getExe pkgs-unstable.wofi} --show drun";
            bars = [ ];
            startup = [
              { command = "waybar"; }
              { command = "blueman-applet"; }
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
          '' + lib.optionalString (nixosConfig.alanix.desktop.profiles.sway.hideCursorMs != null) ''
            seat * hide_cursor ${toString nixosConfig.alanix.desktop.profiles.sway.hideCursorMs}
          '' + lib.optionalString (gameFocusCfg.enable && gameFocusCfg.cursorHideMs != null) ''
            seat * hide_cursor ${toString gameFocusCfg.cursorHideMs}
          '' + lib.optionalString (gameFocusCfg.enable && fullscreenRuleLines != [ ]) ''
            ${lib.concatStringsSep "\n" fullscreenRuleLines}
          '';
        };
      }
    ];
  };
}
