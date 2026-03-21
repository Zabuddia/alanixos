{ config, lib, pkgs, ... }:

let
  cfg = config.trayscale;
in
{
  options.trayscale.enable = lib.mkEnableOption "Trayscale tray applet for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      home.packages = [ pkgs.trayscale ];

      services.trayscale = {
        enable = true;
        hideWindow = true;
      };
    }
  ];
}
