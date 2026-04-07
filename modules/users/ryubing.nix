{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.ryubing;
in
{
  options.ryubing.enable = lib.mkEnableOption "Ryubing for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      home.packages = [ pkgs-unstable.ryubing ];
    }
  ];
}
