{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.remote-desktop;
in
{
  options.alanix.remote-desktop = {
    enable = lib.mkEnableOption "wayvnc VNC remote desktop (WireGuard-restricted)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5900;
      description = "TCP port for wayvnc to listen on.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "buddia";
      description = "User whose Wayland session to serve via wayvnc.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.wireguard.enable;
        message = "alanix.remote-desktop: requires alanix.wireguard.enable = true (VNC is restricted to wg0).";
      }
    ];

    # Restrict VNC access to the WireGuard interface only
    networking.firewall.interfaces.wg0.allowedTCPPorts = [ cfg.port ];

    environment.systemPackages = [ pkgs.wayvnc ];

    # Inject wayvnc as a user systemd service into the specified user's session.
    # wayvnc attaches to the running Wayland compositor via $WAYLAND_DISPLAY.
    # NOTE: requires the user to be logged into Sway — no pre-login access.
    home-manager.users.${cfg.user} = { ... }: {
      systemd.user.services.wayvnc = {
        Unit = {
          Description = "wayvnc VNC server for Wayland session";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${pkgs.wayvnc}/bin/wayvnc 0.0.0.0 ${toString cfg.port}";
          Restart = "on-failure";
          RestartSec = "3s";
        };
        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
      };
    };
  };
}
