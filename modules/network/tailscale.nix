{ lib, config, pkgs, pkgs-unstable, ... }:

let
  cfg = config.alanix.tailscale;
  routingMode =
    if cfg.acceptRoutes then
      "client"
    else
      "none";
  preferenceFlags =
    lib.optionals cfg.acceptRoutes [ "--accept-routes=true" ]
    ++ lib.optionals (cfg.operator != null) [ "--operator=${cfg.operator}" ];
in
{
  options.alanix.tailscale = {
    enable = lib.mkEnableOption "Tailscale";

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Declarative Tailscale address or MagicDNS name used by other repo modules for peer-to-peer connectivity.";
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept subnet routes advertised by other Tailscale nodes.";
    };

    operator = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Unix user allowed to operate Tailscale as an operator (e.g. for serve/funnel).";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.tailscale = {
        enable = true;
        package = pkgs-unstable.tailscale;
        useRoutingFeatures = routingMode;
        extraSetFlags = preferenceFlags;
      };

      systemd.services.alanix-tailscale-ready = {
        description = "Wait for Tailscale interface readiness";
        after = [ "tailscaled.service" ];
        wants = [ "tailscaled.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          iface="${config.services.tailscale.interfaceName}"

          for _ in $(seq 1 60); do
            if ${pkgs.iproute2}/bin/ip link show dev "$iface" >/dev/null 2>&1 \
              && ${config.services.tailscale.package}/bin/tailscale ip -4 | grep -q .; then
              exit 0
            fi
            sleep 1
          done

          echo "Timed out waiting for Tailscale interface $iface to become ready" >&2
          exit 1
        '';
      };
    }
  ]);
}
