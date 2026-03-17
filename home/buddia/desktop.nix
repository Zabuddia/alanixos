{ pkgs, lib, ... }:

{
  home.packages = with pkgs; [ foot wofi waybar pulseaudio swaylock ];

  programs.wlogout = {
    enable = true;
    layout = [
      { label = "lock";      action = "${pkgs.swaylock}/bin/swaylock -f"; text = "Lock";     keybind = "l"; }
      { label = "logout";    action = "loginctl terminate-user $USER";    text = "Logout";   keybind = "e"; }
      { label = "suspend";   action = "systemctl suspend";                text = "Suspend";  keybind = "u"; }
      { label = "shutdown";  action = "systemctl poweroff";               text = "Shutdown"; keybind = "s"; }
      { label = "reboot";    action = "systemctl reboot";                 text = "Reboot";   keybind = "r"; }
    ];
  };

  services.swayidle = {
    enable = true;
    events = [
      { event = "before-sleep"; command = "${pkgs.swaylock}/bin/swaylock -f"; }
      { event = "lock";         command = "${pkgs.swaylock}/bin/swaylock -f"; }
    ];
  };

  programs.waybar = {
    enable = true;
    settings = [{
      layer = "top";
      position = "top";
      height = 32;
      modules-left = [ "sway/workspaces" "sway/mode" ];
      modules-center = [ "clock" ];
      modules-right = [ "cpu" "memory" "network" "pulseaudio" "battery" "tray" "custom/logout" ];

      "sway/workspaces" = {
        all-outputs = false;
      };

      "clock" = {
        format = "{:%a %d %b  %H:%M}";
        format-alt = "{:%Y-%m-%d}";
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
        states = { warning = 30; critical = 15; };
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
      bars = [];
      startup = [
        { command = "waybar"; }
        { command = "swaymsg workspace number 1"; always = false; }
      ];
      keybindings = lib.mkOptionDefault {
        "XF86AudioRaiseVolume" = "exec pactl set-sink-volume @DEFAULT_SINK@ +5%";
        "XF86AudioLowerVolume" = "exec pactl set-sink-volume @DEFAULT_SINK@ -5%";
        "XF86AudioMute" = "exec pactl set-sink-mute @DEFAULT_SINK@ toggle";
        "Mod4+Shift+e" = "exec wlogout";
      };
      input = {
        "type:touchpad" = {
          tap = "enabled";
          click_method = "clickfinger";
          dwt = "enabled";
          natural_scroll = "enabled";
        };
      };
    };
    extraConfig = ''
      bindgesture swipe:3:left workspace next
      bindgesture swipe:3:right workspace prev
    '';
  };
}
