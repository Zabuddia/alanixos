{ lib, config, pkgs-unstable, ... }:

let
  cfg = config.alanix.tailscale;
in
{
  options.alanix.tailscale = {
    enable = lib.mkEnableOption "Tailscale";

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      description = "Accept subnet routes advertised by other Tailscale nodes.";
    };

    operator = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "Unix user allowed to operate Tailscale as an operator (e.g. for serve/funnel).";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.tailscale = {
        enable = true;
        package = pkgs-unstable.tailscale;
        extraUpFlags = lib.optionals cfg.acceptRoutes [ "--accept-routes" ];
        extraSetFlags = lib.optionals (cfg.operator != null) [ "--operator=${cfg.operator}" ];
      };
    }
  ]);
}
