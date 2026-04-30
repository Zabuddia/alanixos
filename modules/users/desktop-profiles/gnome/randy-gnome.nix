{ config, lib, name, nixosConfig, pkgs, ... }:

let
  cfg = config.desktop;
  active = cfg.enable && cfg.profile == "gnome/randy-gnome";
in
{
  config = {
    _assertions = lib.optionals active [
      {
        assertion = nixosConfig.alanix.desktop.profile == "gnome";
        message = "alanix.users.accounts.${name}.desktop.profile = \"gnome/randy-gnome\" requires alanix.desktop.profile = \"gnome\".";
      }
    ];

    home.modules = lib.optionals active [
      ({ lib, ... }:
        let
          inherit (lib.hm.gvariant) mkUint32;
        in
        {
        dconf.enable = true;

        xdg.mimeApps = {
          enable = true;

          defaultApplications = {
            "text/html" = [ "firefox.desktop" ];
            "application/xhtml+xml" = [ "firefox.desktop" ];
            "application/x-www-browser" = [ "firefox.desktop" ];
            "x-scheme-handler/http" = [ "firefox.desktop" ];
            "x-scheme-handler/https" = [ "firefox.desktop" ];
            "x-scheme-handler/about" = [ "firefox.desktop" ];
            "x-scheme-handler/unknown" = [ "firefox.desktop" ];
            "x-scheme-handler/ftp" = [ "firefox.desktop" ];

            "x-scheme-handler/mailto" = [ "org.gnome.Geary.desktop" ];

            "inode/directory" = [ "org.gnome.Nautilus.desktop" ];

            "application/pdf" = [ "firefox.desktop" ];

            "image/jpeg" = [ "org.gnome.Loupe.desktop" ];
            "image/png" = [ "org.gnome.Loupe.desktop" ];
            "image/webp" = [ "org.gnome.Loupe.desktop" ];
            "image/gif" = [ "org.gnome.Loupe.desktop" ];

            "video/mp4" = [ "vlc.desktop" ];
            "video/x-matroska" = [ "vlc.desktop" ];
            "audio/mpeg" = [ "vlc.desktop" ];
            "audio/flac" = [ "vlc.desktop" ];

            "text/plain" = [ "org.gnome.TextEditor.desktop" ];
            "text/markdown" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-mimeapps-list" = [ "org.gnome.TextEditor.desktop" ];
            "text/x-ini" = [ "org.gnome.TextEditor.desktop" ];
            "application/x-desktop" = [ "org.gnome.TextEditor.desktop" ];

            "application/zip" = [ "org.gnome.FileRoller.desktop" ];
            "application/x-tar" = [ "org.gnome.FileRoller.desktop" ];
            "application/x-7z-compressed" = [ "org.gnome.FileRoller.desktop" ];
          };
        };

        home.packages = with pkgs; [
          gnomeExtensions.dash-to-dock
          gnomeExtensions.start-overlay-in-application-view
          gnomeExtensions.no-overview
          gnomeExtensions.appindicator
        ];

        dconf.settings = {
          "org/gnome/shell" = {
            enabled-extensions = [
              "dash-to-dock@micxgx.gmail.com"
              "start-overlay-in-application-view@Hex_cz"
              "no-overview@fthx"
              "appindicatorsupport@rgcjonas.gmail.com"
            ];

            favorite-apps = [
              "codium.desktop"
              "bluebubbles.desktop"
              "firefox.desktop"
              "sparrow-desktop.desktop"
              "org.remmina.Remmina.desktop"
              "writer.desktop"
              "org.gnome.Boxes.desktop"
              "Waydroid.desktop"
              "org.gnome.TextEditor.desktop"
              "org.gnome.Console.desktop"
              "org.gnome.Nautilus.desktop"
              "org.gnome.Calculator.desktop"
              "org.gnome.Settings.desktop"
            ];
          };

          "org/gnome/shell/extensions/dash-to-dock" = {
            dock-position = "LEFT";
            dock-fixed = true;
            extend-height = true;
            click-action = "minimize-or-previews";
            running-indicator-style = "DOTS";
            running-indicator-dominant-color = true;
          };

          "org/gnome/settings-daemon/plugins/color" = {
            night-light-enabled = true;
            night-light-schedule-automatic = true;
          };

          "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
            name = "Launch GNOME Console";
            binding = "<Control><Alt>T";
            command = "kgx";
          };

          "org/gnome/settings-daemon/plugins/media-keys" = {
            custom-keybindings = [ "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/" ];
          };

          "org/gnome/desktop/wm/preferences" = {
            button-layout = ":minimize,maximize,close";
          };

          "org/gnome/mutter" = {
            edge-tiling = true;
            dynamic-workspaces = true;
            workspaces-only-on-primary = true;
          };

          "org/gnome/desktop/interface" = {
            show-battery-percentage = true;
          };

          "org/gnome/desktop/session" = {
            idle-delay = mkUint32 0;
          };

          "org/gnome/settings-daemon/plugins/power" = {
            sleep-inactive-ac-type = "nothing";
            sleep-inactive-ac-timeout = mkUint32 0;
            sleep-inactive-battery-type = "nothing";
            sleep-inactive-battery-timeout = mkUint32 0;
          };
        };

        systemd.user.services.force-idle-delay = {
          Unit = {
            Description = "Force idle-delay to 0 after GNOME login";
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${pkgs.glib}/bin/gsettings set org.gnome.desktop.session idle-delay 0";
            Type = "oneshot";
          };
          Install = {
            WantedBy = [ "default.target" ];
          };
        };
        })
    ];
  };
}
