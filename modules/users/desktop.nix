{ config, lib, name, nixosConfig, pkgs, pkgs-unstable, ... }:

let
  cfg = config.desktop;
  idleCfg = nixosConfig.alanix.desktop.idle;
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

        home.packages =
          (with pkgs; [
            adwaita-icon-theme
            pulseaudio
            swaylock
            brightnessctl
            grim
            hicolor-icon-theme
            slurp
            xfce.thunar
            nnn
            imv
            mpv
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

        programs.foot = {
          enable = true;
          package = pkgs-unstable.foot;
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
            modules-right = [ "cpu" "memory" "network" "pulseaudio" "battery" "tray" "custom/logout" ];

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
              on-scroll-up = "pactl set-sink-volume @DEFAULT_SINK@ +1%";
              on-scroll-down = "pactl set-sink-volume @DEFAULT_SINK@ -1%";
              on-click = "pactl set-sink-mute @DEFAULT_SINK@ toggle";
            };

            "battery" = {
              format = "{capacity}% {icon}";
              format-charging = "{capacity}% ↑";
              format-plugged = "{capacity}% ⚡";
              format-icons = [ "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" ];
              states = {
                warning = 30;
                critical = 15;
              };
              tooltip-format = "{timeTo}";
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
            #battery,
            #tray,
            #custom-logout {
              padding: 0 12px;
              color: #cdd6f4;
              background: transparent;
            }

            #battery.warning {
              color: #fab387;
            }

            #battery.critical:not(.charging) {
              color: #f38ba8;
            }

            #network.disconnected {
              color: #f38ba8;
            }
          '';
        };

        wayland.windowManager.sway = {
          enable = true;
          config = {
            modifier = "Mod4";
            terminal = "${pkgs-unstable.foot}/bin/foot";
            bars = [ ];
            startup = [
              { command = "waybar"; }
              { command = "sleep 2 && swaymsg workspace number 1"; always = false; }
            ];
            keybindings = lib.mkOptionDefault {
              "XF86AudioRaiseVolume" = "exec pactl set-sink-volume @DEFAULT_SINK@ +5%";
              "XF86AudioLowerVolume" = "exec pactl set-sink-volume @DEFAULT_SINK@ -5%";
              "XF86AudioMute" = "exec pactl set-sink-mute @DEFAULT_SINK@ toggle";
              "XF86MonBrightnessUp" = "exec brightnessctl set +5%";
              "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
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
