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
  installed-apps       List installed desktop application IDs
  open-apps            List application IDs with open windows
  launch APP_ID        Launch an installed desktop application
  close-app APP_ID     Close every open window for an application ID
  focused              Return focused-window metadata as JSON
  outputs              Return active Sway outputs as JSON
  screenshot           Write a PNG of the current desktop to stdout
  clipboard-read       Write the current text clipboard to stdout
  clipboard-write      Replace the text clipboard with stdin
  reboot               Reboot this host
  shutdown             Power off this host
EOF
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then
        shift
      fi

      validate_app_id() {
        case "$1" in
          ""|*[!A-Za-z0-9_.+-]*)
            echo "Invalid desktop application ID: $1" >&2
            return 64
            ;;
        esac
      }

      # Power actions need no graphical session, so dispatch them before the
      # Sway session detection below.
      case "$action" in
        reboot)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          exec sudo systemctl reboot
          ;;
        shutdown)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          exec sudo systemctl poweroff
          ;;
      esac

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
        installed-apps)
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
        open-apps)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          swaymsg -r -t get_tree \
            | jq -r '
                [
                  .. | objects
                  | select((.pid? // 0) > 0)
                  | (.app_id? // .window_properties?.class? // empty)
                  | select(type == "string" and length > 0)
                ]
                | unique[]
              '
          ;;
        launch)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          validate_app_id "$1"
          printf -v launch_command '%q %q' \
            ${lib.escapeShellArg config.appLauncher.desktopCommand} "$1"
          exec swaymsg exec -- "$launch_command"
          ;;
        close-app)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          validate_app_id "$1"
          tree="$(swaymsg -r -t get_tree)"
          mapfile -t container_ids < <(
            printf '%s\n' "$tree" \
              | jq -r --arg target "$1" '
                  .. | objects
                  | select((.pid? // 0) > 0)
                  | (.app_id? // .window_properties?.class? // empty) as $app
                  | select(
                      ($app | type) == "string"
                      and ($app | ascii_downcase) == ($target | ascii_downcase)
                    )
                  | .id
                '
          )
          if [ "''${#container_ids[@]}" -eq 0 ]; then
            echo "Application has no open windows: $1" >&2
            exit 66
          fi
          failed=0
          for container_id in "''${container_ids[@]}"; do
            swaymsg "[con_id=$container_id]" kill >/dev/null || failed=1
          done
          exit "$failed"
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
          clipboard_file="$(mktemp "$runtime_dir/alanix-clipboard.XXXXXX")"
          trap 'rm -f "$clipboard_file"' EXIT
          chmod 600 "$clipboard_file"
          cat > "$clipboard_file"
          # wl-copy keeps a background process alive to own the clipboard.
          # Detach all of its standard descriptors from the SSH session so the
          # caller can return as soon as the clipboard contents are installed.
          wl-copy --type text/plain < "$clipboard_file" >/dev/null 2>&1
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
