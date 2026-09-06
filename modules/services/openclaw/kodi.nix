{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.openclaw.kodi;
  kodiControl = pkgs.writeShellApplication {
    name = "kodi-control";
    runtimeInputs = [ pkgs.curl pkgs.openssh pkgs.python3 ];
    text = ''
      exec python3 ${./kodi-control/kodi_control.py} \
        --host ${lib.escapeShellArg cfg.host} \
        --url ${lib.escapeShellArg cfg.rpcUrl} \
        --connect-timeout ${toString cfg.connectTimeout} \
        ${lib.optionalString (cfg.invidiousUrl != null) "--invidious-url ${lib.escapeShellArg cfg.invidiousUrl}"} \
        "$@"
    '';
  };
in
{
  options.alanix.openclaw.kodi = {
    enable = lib.mkEnableOption "structured Kodi control for OpenClaw";

    host = lib.mkOption {
      type = lib.types.str;
      default = "alan-tv";
      description = "Inventory hostname reached over SSH for Kodi control.";
    };

    rpcUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:8080/jsonrpc";
      description = "Kodi JSON-RPC URL as seen from the target host.";
    };

    invidiousUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Invidious instance URL used to resolve YouTube channels and videos.
        Required for title and channel resolution; it should match the instance
        configured for the target Kodi's Invidious add-on.
      '';
    };

    connectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "SSH connection timeout in seconds.";
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.openclaw.gateway.enable;
        message = "alanix.openclaw.kodi requires alanix.openclaw.gateway.enable.";
      }
    ];

    alanix.openclaw.packages = [ kodiControl ];
  };
}
