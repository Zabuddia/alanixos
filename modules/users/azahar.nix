{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.azahar;
in
{
  options.azahar.enable = lib.mkEnableOption "Azahar for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      home.packages = [ pkgs-unstable.azahar ];
    }
  ];
}
