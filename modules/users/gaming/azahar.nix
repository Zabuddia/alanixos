{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.azahar;
in
{
  options.azahar.enable = lib.mkEnableOption "Azahar for this user";

  config.appLauncher.apps.azahar = lib.mkIf cfg.enable {
    label = "Azahar";
    icon = "mdi:nintendo-3ds";
    command = lib.getExe pkgs-unstable.azahar;
    processNames = [ "azahar" ];
  };

  config.home.modules = lib.optionals cfg.enable [
    {
      home.packages = [ pkgs-unstable.azahar ];
    }
  ];
}
