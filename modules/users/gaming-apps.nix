{ config, lib, nixosConfig, ... }:

let
  gaming = nixosConfig.alanix.desktop.gaming;
in
{
  config.appLauncher.apps = lib.mkMerge [
    (lib.mkIf (gaming.enable && gaming.steam.enable) {
      steam = {
        label = "Steam";
        icon = "mdi:steam";
        command = "steam -gamepadui";
        processNames = [ "steam" "steamwebhelper" ];
      };
    })
    (lib.mkIf (gaming.enable && gaming.heroic.enable) {
      heroic = {
        label = "Heroic";
        icon = "mdi:gamepad-variant";
        command = "heroic --console --fullscreen";
        processNames = [ "heroic" ];
      };
    })
  ];
}
