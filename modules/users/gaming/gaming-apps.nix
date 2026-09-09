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
        closeCommand = "steam -shutdown";
      };
    })
    (lib.mkIf (gaming.enable && gaming.heroic.enable) {
      heroic = {
        label = "Heroic";
        icon = "mdi:gamepad-variant";
        command = "heroic --force-device-scale-factor=1 --console --fullscreen";
        commandLineContains = [ "/opt/heroic/resources/app.asar" ];
        windowIds = [ "com.heroicgameslauncher.hgl" "heroic" ];
      };
    })
  ];
}
