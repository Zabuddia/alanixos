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

  desktopControl = pkgs.writeShellApplication {
    name = "desktop-control";
    runtimeInputs = [ pkgs.imagemagick pkgs.openssh ];
    text = ''
      usage() {
        cat >&2 <<'EOF'
Usage: desktop-control HOST ACTION [ARGUMENT]

Actions: apps, launch APP_ID, close-current, focused, outputs, screenshot,
         clipboard-read, clipboard-write

Screenshot writes PNG bytes to stdout. Clipboard-write reads text from stdin.
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
        apps|close-current|focused|outputs|screenshot|clipboard-read|clipboard-write)
          [ "$#" -eq 0 ] || { usage; exit 2; }
          ;;
        launch)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          case "$1" in
            ""|*[!A-Za-z0-9_.+-]*)
              echo "Invalid desktop application ID: $1" >&2
              exit 64
              ;;
          esac
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

      if [ "$host" = "$(hostname)" ]; then
        if [ "$action" = screenshot ]; then
          ${lib.escapeShellArg localControl} screenshot | resize_screenshot
          exit
        fi
        exec ${lib.escapeShellArg localControl} "$action" "$@"
      fi

      if [ "$action" = screenshot ]; then
        ssh \
          -o BatchMode=yes \
          -o ConnectTimeout=${toString cfg.connectTimeout} \
          -- "$host" ${lib.escapeShellArg localControl} screenshot \
          | resize_screenshot
        exit
      fi

      exec ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=${toString cfg.connectTimeout} \
        -- "$host" ${lib.escapeShellArg localControl} "$action" "$@"
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

    alanix.openclaw.packages = [ desktopControl ];
  };
}
