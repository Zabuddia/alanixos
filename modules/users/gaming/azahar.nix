{ config, lib, pkgs, pkgs-unstable, ... }:

let
  cfg = config.azahar;
in
{
  options.azahar = {
    enable = lib.mkEnableOption "Azahar for this user";

    confirmExit = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether Azahar asks for confirmation before closing.";
    };
  };

  config.appLauncher.apps.azahar = lib.mkIf cfg.enable {
    label = "Azahar";
    icon = "mdi:nintendo-3ds";
    command = lib.getExe pkgs-unstable.azahar;
    processNames = [ "azahar" ];
    windowIds = [ "org.azahar_emu.Azahar" ];
  };

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ pkgs-unstable.azahar ];

      home.activation.writeAzaharSettings = lib.mkIf (cfg.confirmExit != null) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        configDir="${config.home.homeDirectory}/.config/azahar-emu"
        configFile="$configDir/qt-config.ini"
        mkdir -p "$configDir"
        touch "$configFile"
        chmod 600 "$configFile"

        ${pkgs.crudini}/bin/crudini --set "$configFile" UI 'confirmClose\default' false
        ${pkgs.crudini}/bin/crudini --set "$configFile" UI confirmClose ${lib.boolToString cfg.confirmExit}
      '');
    })
  ];
}
