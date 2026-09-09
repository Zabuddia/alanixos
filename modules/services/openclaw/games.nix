{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.openclaw.games;
  remoteControl = "/etc/profiles/per-user/${cfg.targetUser}/bin/alanix-game-control";

  gameControl = pkgs.writeShellApplication {
    name = "game-control";
    runtimeInputs = [ pkgs.jq pkgs.openssh ];
    text = ''
      usage() {
        cat >&2 <<'EOF'
Usage: game-control ACTION [ARGUMENT]

Actions:
  list
  search TITLE
  launch GAME_ID
  close GAME_ID
  running
EOF
      }

      action="''${1:-}"
      if [ "$#" -gt 0 ]; then shift; fi
      case "$action" in
        list|running) [ "$#" -eq 0 ] || { usage; exit 2; } ;;
        search) [ "$#" -eq 1 ] || { usage; exit 2; } ;;
        launch|close)
          [ "$#" -eq 1 ] || { usage; exit 2; }
          if [[ ! "$1" =~ ^(steam:[0-9]+|rom:[a-z0-9]+:[a-f0-9]{16}|heroic:(legendary|gog|nile):[a-f0-9]{16})$ ]]; then
            echo "Invalid game ID; use an ID returned by list or search" >&2
            exit 64
          fi
          ;;
        *) usage; exit 2 ;;
      esac

      set +e
      output="$(ssh -o BatchMode=yes -o ConnectTimeout=${toString cfg.connectTimeout} \
        -- ${lib.escapeShellArg cfg.host} ${lib.escapeShellArg remoteControl} "$action" "$@" 2>&1)"
      status=$?
      set -e
      if [ "$status" -ne 0 ]; then
        if jq -e . >/dev/null 2>&1 <<<"$output"; then
          printf '%s\n' "$output"
        else
          jq -cn --arg message "$output" --arg host ${lib.escapeShellArg cfg.host} \
            '{ok:false,host:$host,error:{code:"unavailable",message:$message}}'
        fi
        exit "$status"
      fi
      printf '%s\n' "$output"
    '';
  };
in
{
  options.alanix.openclaw.games = {
    enable = lib.mkEnableOption "bounded game discovery and control on alan-tv";
    host = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9.-]+$";
      default = "alan-tv";
      description = "Fixed game computer.";
    };
    targetUser = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z_][A-Za-z0-9_-]*$";
      default = "buddia";
      description = "User owning the graphical game session.";
    };
    connectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "SSH connection timeout in seconds.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.alanix.openclaw.gateway.enable;
      message = "alanix.openclaw.games requires alanix.openclaw.gateway.enable.";
    }];
    alanix.openclaw.packages = [ gameControl ];
  };
}
