{ config, lib, ... }:

let
  cfg = config.syncthingTray;
in
{
  options.syncthingTray.enable = lib.mkEnableOption "Syncthing tray applet for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      services.syncthing.tray.enable = true;
    }
  ];
}
