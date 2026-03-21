{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.remote-desktop;
  userCfg =
    if cfg.user != null then
      lib.attrByPath [ "alanix" "users" "accounts" cfg.user ] null config
    else
      null;
  userHomeReady = userCfg != null && userCfg.enable && userCfg.home.enable;
in
{
  options.alanix.remote-desktop = {
    enable = lib.mkEnableOption "wayvnc VNC remote desktop (WireGuard-restricted)";

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the wayvnc user service should start automatically with the graphical session.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5900;
      description = "TCP port for wayvnc to listen on.";
    };

    output = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Specific Sway output for wayvnc to capture.";
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "User whose Wayland session to serve via wayvnc.";
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
        assertion = cfg.user != null;
        message = "alanix.remote-desktop.user must be set when alanix.remote-desktop.enable = true.";
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

    environment.systemPackages = [ pkgs.wayvnc ];

    # wayvnc attaches to the running Wayland compositor via $WAYLAND_DISPLAY.
    # NOTE: requires the user to be logged into Sway — no pre-login access.
    home-manager.users = lib.mkIf userHomeReady {
      ${cfg.user} = {
        systemd.user.services.wayvnc = {
          Unit = {
            Description = "wayvnc VNC server for Wayland session";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStartPre = "${pkgs.bash}/bin/bash -lc 'runtime_dir=\"$XDG_RUNTIME_DIR\"; if [ -z \"$runtime_dir\" ]; then runtime_dir=%t; fi; for ((i = 0; i < 60; i++)); do sway_sock=$(${pkgs.findutils}/bin/find \"$runtime_dir\" -maxdepth 1 -type s -name \"sway-ipc.*.sock\" | ${pkgs.coreutils}/bin/head -n1); if [ -n \"$sway_sock\" ] && SWAYSOCK=\"$sway_sock\" ${pkgs.sway}/bin/swaymsg -r -t get_outputs 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q '\"active\": true'; then exit 0; fi; sleep 1; done; echo \"wayvnc: no active Sway outputs became available\" >&2; exit 1'";
            ExecStart = "${pkgs.wayvnc}/bin/wayvnc ${lib.optionalString (cfg.output != null) "-o ${lib.escapeShellArg cfg.output} "}0.0.0.0 ${toString cfg.port}";
            Restart = "on-failure";
            RestartSec = "3s";
          };
          Install = lib.mkIf cfg.autoStart {
            WantedBy = [ "graphical-session.target" ];
          };
        };
      };
    };
  };
}
