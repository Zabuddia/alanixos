{ config, lib, pkgs, utils, ... }:

let
  cfg = config.alanix.remote-desktop;
  userCfg = lib.attrByPath [ "alanix" "users" "accounts" cfg.user ] null config;
  wayvncArgs =
    [
      "--max-fps=${toString cfg.maxFps}"
    ]
    ++ lib.optionals (cfg.keyboardLayout != null) [ "--keyboard=${cfg.keyboardLayout}" ]
    ++ lib.optionals cfg.renderCursor [ "--render-cursor" ]
    ++ lib.optionals cfg.transientSeat [ "--transient-seat" ]
    ++ cfg.extraArgs
    ++ [ "0.0.0.0" (toString cfg.port) ];
in
{
  options.alanix.remote-desktop = {
    enable = lib.mkEnableOption "wayvnc VNC remote desktop (WireGuard-restricted)";

    port = lib.mkOption {
      type = lib.types.port;
      description = "TCP port for wayvnc to listen on.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "User whose Wayland session to serve via wayvnc.";
    };

    keyboardLayout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "us";
      description = "Optional wayvnc keyboard layout override to better match the client keyboard.";
    };

    maxFps = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Maximum frame rate for remote desktop capture.";
    };

    renderCursor = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Render the cursor in the captured stream for better client compatibility.";
    };

    transientSeat = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use a transient wlroots seat for each remote session.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional raw wayvnc command line arguments.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.wireguard.enable;
        message = "alanix.remote-desktop: requires alanix.wireguard.enable = true (VNC is restricted to wg0).";
      }
      {
        assertion = config.alanix.desktop.enable;
        message = "alanix.remote-desktop: requires alanix.desktop.enable = true.";
      }
      {
        assertion = userCfg != null && userCfg.enable;
        message = "alanix.remote-desktop.user must reference an enabled alanix.users.accounts entry.";
      }
      {
        assertion = userCfg != null && userCfg.enable && userCfg.home.enable;
        message = "alanix.remote-desktop.user must reference an alanix.users.accounts entry with home.enable = true.";
      }
    ];

    # Restrict VNC access to the WireGuard interface only
    networking.firewall.interfaces.wg0.allowedTCPPorts = [ cfg.port ];

    programs.wayvnc.enable = true;

    # wayvnc attaches to the running Wayland compositor via $WAYLAND_DISPLAY.
    # NOTE: requires the user to be logged into Sway — no pre-login access.
    alanix._internal.homeModules.${cfg.user} = [
      {
        systemd.user.services.wayvnc = {
          Unit = {
            Description = "wayvnc VNC server for Wayland session";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = utils.escapeSystemdExecArgs ([ "${pkgs.wayvnc}/bin/wayvnc" ] ++ wayvncArgs);
            Restart = "on-failure";
            RestartSec = "3s";
          };
          Install = {
            WantedBy = [ "graphical-session.target" ];
          };
        };
      }
    ];
  };
}
