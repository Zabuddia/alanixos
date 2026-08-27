{ config, lib, pkgs, ... }:

let
  cfg = config.appLauncher;

  appType = lib.types.submodule ({ name, ... }: {
    options = {
      label = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Human-readable application name.";
      };

      icon = lib.mkOption {
        type = lib.types.str;
        default = "mdi:application";
        description = "Material Design icon used by integrations such as Home Assistant.";
      };

      command = lib.mkOption {
        type = lib.types.str;
        description = "Fixed command used to launch the application.";
      };

      processNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Process names that prevent launching another instance.";
      };
    };
  });

  processRunningShell = processNames: ''
    process_names=${lib.escapeShellArg (lib.concatStringsSep "\n" processNames)}

    process_is_running() {
      while IFS= read -r process_name; do
        [ -n "$process_name" ] || continue
        if ${pkgs.procps}/bin/pgrep -x -- "$process_name" >/dev/null 2>&1; then
          return 0
        fi
      done <<< "$process_names"
      return 1
    }
  '';

  launchOnce = appId: app: pkgs.writeShellScript "alanix-open-${appId}" ''
    set -u

    ${processRunningShell app.processNames}

    launch_lock_dir="''${XDG_RUNTIME_DIR:-/tmp}/alanix-app-launcher-locks"
    ${pkgs.coreutils}/bin/mkdir -p "$launch_lock_dir"
    exec 9>"$launch_lock_dir/${appId}.lock"

    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      exit 0
    fi

    if process_is_running; then
      exit 0
    fi

    exec ${app.command}
  '';

  launchCommands = lib.mapAttrs (appId: app: toString (launchOnce appId app)) cfg.apps;

  desktopCommand = pkgs.writeShellScript "alanix-open-desktop-app" ''
    set -eu

    desktop_id="''${1:-}"
    case "$desktop_id" in
      ""|*/*|*$'\n'*|*$'\r'*)
        echo "Invalid desktop application ID: $desktop_id" >&2
        exit 2
        ;;
    esac

    case "$desktop_id" in
      *.desktop) desktop_file="$desktop_id" ;;
      *) desktop_file="$desktop_id.desktop" ;;
    esac

    data_dirs="''${XDG_DATA_HOME:-$HOME/.local/share}:''${XDG_DATA_DIRS:-/etc/profiles/per-user/$USER/share:/run/current-system/sw/share:/usr/local/share:/usr/share}"
    found=0
    old_ifs="$IFS"
    IFS=:
    for data_dir in $data_dirs; do
      if [ -f "$data_dir/applications/$desktop_file" ]; then
        found=1
        break
      fi
    done
    IFS="$old_ifs"

    if [ "$found" -ne 1 ]; then
      echo "Desktop application is not installed: $desktop_id" >&2
      exit 3
    fi

    launch_lock_dir="''${XDG_RUNTIME_DIR:-/tmp}/alanix-app-launcher-locks"
    ${pkgs.coreutils}/bin/mkdir -p "$launch_lock_dir"
    exec 9>"$launch_lock_dir/desktop-$desktop_id.lock"

    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      exit 0
    fi

    exec ${pkgs.gtk3}/bin/gtk-launch "''${desktop_file%.desktop}"
  '';
in
{
  options.appLauncher = {
    desktop.enable = lib.mkEnableOption "launching installed freedesktop applications by desktop-file ID";

    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = { };
      description = "Applications with declarative launch and duplicate-instance safeguards.";
    };

    launchCommands = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Generated safe commands for registered applications.";
    };

    desktopCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Safe command for launching an installed desktop application by desktop-file ID.";
    };
  };

  config = {
    appLauncher = {
      inherit launchCommands;
      desktopCommand = toString desktopCommand;
    };

    home.modules = lib.optionals cfg.desktop.enable [ {
      home.packages = [ pkgs.gtk3 ];
    } ];
  };
}
