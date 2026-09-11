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
        # Sway's gameFocus rules already force this window fullscreen once it
        # maps (see desktop-profiles/sway/default.nix). Also passing
        # --fullscreen here made Electron race its own native fullscreen
        # transition against Sway's, which intermittently left the window
        # positioned and sized incorrectly with the rest of the output black.
        command = "heroic --force-device-scale-factor=1 --console";
        commandLineContains = [ "/opt/heroic/resources/app.asar" ];
        windowIds = [ "com.heroicgameslauncher.hgl" "heroic" ];
      };
    })
  ];
}
