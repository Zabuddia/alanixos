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

      closeCommand = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional fixed command used to close the application cleanly.";
      };
    };
  });

  processRunningShell = processNames: ''
    process_names=${lib.escapeShellArg (lib.concatStringsSep "\n" processNames)}

    matching_process_ids() {
      for process_dir in /proc/[0-9]*; do
        [ -r "$process_dir/comm" ] && [ -r "$process_dir/cmdline" ] || continue
        process_id="''${process_dir##*/}"
        process_comm="$(<"$process_dir/comm")"
        process_argv0=""
        IFS= read -r -d "" process_argv0 < "$process_dir/cmdline" 2>/dev/null || true
        process_executable="''${process_argv0##*/}"
        while IFS= read -r process_name; do
          [ -n "$process_name" ] || continue
          if [ "$process_comm" = "$process_name" ] || [ "$process_executable" = "$process_name" ]; then
            printf '%s\n' "$process_id"
            break
          fi
        done <<< "$process_names"
      done
    }

    process_is_running() {
      [ -n "$(matching_process_ids)" ]
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

  runningCommands = lib.mapAttrs (appId: app: toString (pkgs.writeShellScript "alanix-is-running-${appId}" ''
    set -u
    ${processRunningShell app.processNames}
    process_is_running
  '')) cfg.apps;

  closeCommands = lib.mapAttrs (appId: app: toString (pkgs.writeShellScript "alanix-close-${appId}" (
    if app.closeCommand != null then
      ''exec ${app.closeCommand}''
    else
      ''
        set -u
        ${processRunningShell app.processNames}
        mapfile -t process_ids < <(matching_process_ids)
        if [ "''${#process_ids[@]}" -gt 0 ]; then
          kill -TERM -- "''${process_ids[@]}" 2>/dev/null || true
        fi

        for _ in {1..10}; do
          process_is_running || exit 0
          ${pkgs.coreutils}/bin/sleep 1
        done
        exit 1
      ''
  ))) cfg.apps;

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

  closeFocusedCommand = pkgs.writeShellScript "alanix-close-focused-app" ''
    set -eu

    exec ${pkgs.sway}/bin/swaymsg kill
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

    closeCommands = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Generated targeted commands for closing registered applications.";
    };

    runningCommands = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Generated commands that detect registered applications by process name or executable.";
    };

    desktopCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Safe command for launching an installed desktop application by desktop-file ID.";
    };

    closeFocusedCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Command that asks Sway to close the currently focused application window.";
    };
  };

  config = {
    appLauncher = {
      inherit launchCommands;
      inherit closeCommands;
      inherit runningCommands;
      desktopCommand = toString desktopCommand;
      closeFocusedCommand = toString closeFocusedCommand;
    };

    home.modules = lib.optionals cfg.desktop.enable [ {
      home.packages = [ pkgs.gtk3 ];
    } ];
  };
}
