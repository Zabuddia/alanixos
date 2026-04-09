{ config, lib, name, nixosConfig, pkgs, pkgs-unstable, ... }:

let
  cfg = config.desktop;
  idleCfg = nixosConfig.alanix.desktop.idle;
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
          TerminalEmulator=foot
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
              on-scroll-up = "${volumeRaiseCommand}";
              on-scroll-down = "${volumeLowerCommand}";
              on-click = "${volumeMuteToggleCommand}";
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
          extraConfigEarly = ''
            include /etc/sway/config.d/*
          '';
          config = {
            modifier = "Mod4";
            terminal = "${pkgs-unstable.foot}/bin/foot";
            bars = [ ];
            startup = [
              { command = "waybar"; }
              { command = "blueman-applet"; }
              { command = "swayosd-server"; }
              { command = "sleep 2 && swaymsg workspace number 1"; always = false; }
            ];
            keybindings = lib.mkOptionDefault {
              "XF86AudioRaiseVolume" = "exec ${volumeRaiseCommand}";
              "XF86AudioLowerVolume" = "exec ${volumeLowerCommand}";
              "XF86AudioMute" = "exec ${volumeMuteToggleCommand}";
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
