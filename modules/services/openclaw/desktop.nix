{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.desktop;
  allowedHostCases = lib.concatMapStringsSep "\n" (host: "    ${lib.escapeShellArg host}) ;;") cfg.hosts;
  openclawUser =
    if config.alanix.openclaw.user != null then
      config.alanix.openclaw.user
    else
      "openclaw";
  localControl = "/etc/profiles/per-user/${openclawUser}/bin/alanix-desktop-control";

  desktopInspect = pkgs.writeShellApplication {
    name = "desktop-inspect";
    runtimeInputs = [ pkgs.imagemagick pkgs.jq pkgs.openssh ];
    text = ''
      usage() {
        cat >&2 <<'EOF'
Usage: desktop-inspect HOST ACTION

Actions: status, apps, focused, outputs, screenshot, clipboard

All actions return JSON except screenshot, which writes PNG bytes to stdout.
EOF
      }

      host="''${1:-}"
      action="''${2:-}"
      if [ "$#" -ge 2 ]; then
        shift 2
      else
        usage
        exit 2
      fi

      case "$host" in
${allowedHostCases}
        *)
          echo "Desktop host is not allowlisted: $host" >&2
          exit 64
          ;;
      esac

      case "$action" in
        status|apps|focused|outputs|screenshot|clipboard)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          ;;
        *)
          usage
          exit 2
          ;;
      esac

      resize_screenshot() {
        magick png:- \
          -resize '${toString cfg.screenshotMaxWidth}x${toString cfg.screenshotMaxHeight}>' \
          -strip png:-
      }

      remote_action="$action"
      [ "$action" != clipboard ] || remote_action=clipboard-read
      run_remote() {
        if [ "$host" = "$(hostname)" ]; then
          ${lib.escapeShellArg localControl} "$remote_action"
        else
          ssh -o BatchMode=yes -o ConnectTimeout=${toString cfg.connectTimeout} \
            -- "$host" ${lib.escapeShellArg localControl} "$remote_action"
        fi
      }

      if [ "$action" = screenshot ]; then
        run_remote | resize_screenshot
        exit
      fi
      if [ "$action" = status ]; then
        remote_action=focused
      fi
      set +e
      output="$(run_remote 2>&1)"
      status=$?
      set -e
      if [ "$status" -ne 0 ]; then
        jq -cn --arg host "$host" --arg message "$output" \
          '{available:false,host:$host,error:{code:"unavailable",message:$message}}'
        exit 69
      fi
      case "$action" in
        status) jq -cn --arg host "$host" '{available:true,host:$host}' ;;
        apps) printf '%s\n' "$output" | jq -Rsc --arg host "$host" '{available:true,host:$host,apps:(split("\n")|map(select(length>0)))}' ;;
        focused) jq -cn --arg host "$host" --argjson value "$output" '{available:true,host:$host,focused:$value}' ;;
        outputs) jq -cn --arg host "$host" --argjson value "$output" '{available:true,host:$host,outputs:$value}' ;;
        clipboard) jq -cn --arg host "$host" --arg value "$output" '{available:true,host:$host,text:$value}' ;;
      esac
    '';
  };

  desktopControl = pkgs.writeShellApplication {
    name = "desktop-control";
    runtimeInputs = [ pkgs.jq pkgs.openssh ];
    text = ''
      usage() {
        echo "Usage: desktop-control HOST {launch APP_ID|close-app|clipboard-write|reboot|shutdown}" >&2
      }
      host="''${1:-}"; action="''${2:-}"
      [ "$#" -ge 2 ] || { usage; exit 2; }
      shift 2
      case "$host" in
${allowedHostCases}
        *) echo "Desktop host is not allowlisted: $host" >&2; exit 64 ;;
      esac
      case "$action" in
        launch)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          case "$1" in ""|*[!A-Za-z0-9_.+-]*) echo "Invalid desktop application ID: $1" >&2; exit 64 ;; esac
          ;;
        close-app|clipboard-write|reboot|shutdown) [ "$#" -eq 0 ] || { usage; exit 2; } ;;
        *) usage; exit 2 ;;
      esac
      set +e
      if [ "$host" = "$(hostname)" ]; then
        output="$(${lib.escapeShellArg localControl} "$action" "$@" 2>&1)"
      else
        output="$(ssh -o BatchMode=yes -o ConnectTimeout=${toString cfg.connectTimeout} \
          -- "$host" ${lib.escapeShellArg localControl} "$action" "$@" 2>&1)"
      fi
      status=$?
      set -e
      if [ "$status" -ne 0 ]; then
        jq -cn --arg host "$host" --arg action "$action" --arg message "$output" \
          '{ok:false,available:false,host:$host,operation:$action,error:{code:"unavailable",message:$message}}'
        exit 69
      fi
      jq -cn --arg host "$host" --arg action "$action" '{ok:true,available:true,host:$host,operation:$action}'
    '';
  };
in
{
  options.alanix.openclaw.desktop = {
    enable = lib.mkEnableOption "allowlisted desktop control through SSH";

    hosts = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "^[A-Za-z0-9.-]+$");
      default = [ ];
      description = "Inventory hostnames on which alanix-desktop-control may run.";
    };

    connectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "SSH connection timeout in seconds.";
    };

    screenshotMaxWidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1280;
      description = "Maximum width of screenshots returned by desktop-control.";
    };

    screenshotMaxHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 720;
      description = "Maximum height of screenshots returned by desktop-control.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "alanix.openclaw.desktop requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = cfg.hosts != [ ];
        message = "alanix.openclaw.desktop.hosts must contain at least one host.";
      }
      {
        assertion = lib.length cfg.hosts == lib.length (lib.unique cfg.hosts);
        message = "alanix.openclaw.desktop.hosts must not contain duplicates.";
      }
    ];

    alanix.openclaw.packages = [ desktopInspect desktopControl ];
  };
}
