{ config, lib, pkgs, ... }:

let
  cfg = config.agentControl;

  control = pkgs.writeShellApplication {
    name = "alanix-desktop-control";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      grim
      jq
      sway
      wl-clipboard
    ];
    text = ''
      usage() {
        cat >&2 <<'EOF'
Usage: alanix-desktop-control ACTION [ARGUMENT]

Actions:
  apps                 List installed desktop application IDs
  launch APP_ID        Launch an installed desktop application
  close-app            Close the focused application
  focused              Return focused-window metadata as JSON
  outputs              Return active Sway outputs as JSON
  screenshot           Write a PNG of the current desktop to stdout
  clipboard-read       Write the current text clipboard to stdout
  clipboard-write      Replace the text clipboard with stdin
EOF
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then
        shift
      fi

      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      export XDG_RUNTIME_DIR="$runtime_dir"

      if [ -z "''${SWAYSOCK:-}" ] || [ ! -S "''${SWAYSOCK:-}" ]; then
        SWAYSOCK=""
        for candidate in "$runtime_dir"/sway-ipc.*.sock; do
          [ -S "$candidate" ] || continue
          if swaymsg -s "$candidate" -r -t get_version >/dev/null 2>&1; then
            SWAYSOCK="$candidate"
            break
          fi
        done
        export SWAYSOCK
      fi
      if [ -z "''${SWAYSOCK:-}" ] || [ ! -S "$SWAYSOCK" ]; then
        echo "No active Sway session was found" >&2
        exit 69
      fi

      if [ -z "''${WAYLAND_DISPLAY:-}" ] || [ ! -S "$runtime_dir/''${WAYLAND_DISPLAY:-}" ]; then
        wayland_socket="$(find "$runtime_dir" -maxdepth 1 -type s -name 'wayland-[0-9]*' -print -quit)"
        if [ -n "$wayland_socket" ]; then
          WAYLAND_DISPLAY="$(basename "$wayland_socket")"
          export WAYLAND_DISPLAY
        fi
      fi

      case "$action" in
        apps)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          data_dirs="''${XDG_DATA_HOME:-$HOME/.local/share}:''${XDG_DATA_DIRS:-/etc/profiles/per-user/$USER/share:/run/current-system/sw/share:/usr/local/share:/usr/share}"
          old_ifs="$IFS"
          IFS=:
          for data_dir in $data_dirs; do
            for desktop_file in "$data_dir"/applications/*.desktop; do
              [ -f "$desktop_file" ] || continue
              basename "$desktop_file" .desktop
            done
          done
          IFS="$old_ifs"
          sort -fu
          ;;
        launch)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          case "$1" in
            ""|*[!A-Za-z0-9_.+-]*)
              echo "Invalid desktop application ID: $1" >&2
              exit 64
              ;;
          esac
          printf -v launch_command '%q %q' \
            ${lib.escapeShellArg config.appLauncher.desktopCommand} "$1"
          exec swaymsg exec -- "$launch_command"
          ;;
        close-app)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          exec ${lib.escapeShellArg config.appLauncher.closeFocusedCommand}
          ;;
        focused)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          swaymsg -r -t get_tree \
            | jq -c '
                first(
                  .. | objects | select(.focused? == true)
                  | {
                      id,
                      name,
                      app_id,
                      pid,
                      shell,
                      workspace: (.workspace // null),
                      rect
                    }
                ) // {}
              '
          ;;
        outputs)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          swaymsg -r -t get_outputs \
            | jq -c '[.[] | select(.active) | {name, make, model, rect, focused}]'
          ;;
        screenshot)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
            echo "No active Wayland display was found" >&2
            exit 69
          fi
          exec grim -
          ;;
        clipboard-read)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
            echo "No active Wayland display was found" >&2
            exit 69
          fi
          exec wl-paste --no-newline --type text
          ;;
        clipboard-write)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
            echo "No active Wayland display was found" >&2
            exit 69
          fi
          exec wl-copy --type text/plain
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.agentControl.enable =
    lib.mkEnableOption "bounded local desktop control for the Alanix agent bridge";

  config = {
    appLauncher.desktop.enable = lib.mkIf cfg.enable true;

    _assertions = lib.optionals cfg.enable [
      {
        assertion = config.desktop.enable && config.desktop.profile == "sway/default";
        message = "alanix user agentControl requires the sway/default desktop profile.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        home.packages = [ control ];
      }
    ];
  };
}
