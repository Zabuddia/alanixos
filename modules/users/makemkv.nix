{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.makemkv;
in
{
  options.makemkv = {
    enable = lib.mkEnableOption "MakeMKV for this user";

    betaKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "MakeMKV beta key written to ~/.MakeMKV/settings.conf.";
    };
  };

  config = lib.mkIf cfg.enable {
    _systemRequirements = {
      extraGroups = [ "cdrom" ];
      kernelModules = [ "sg" ];
    };

    home.modules = [
      {
        home.packages = [ pkgs-unstable.makemkv ];

        home.file.".MakeMKV/settings.conf" = lib.mkIf (cfg.betaKey != null) {
          text = ''
            app_Key = "${cfg.betaKey}"
          '';
        };
      }
    ];
  };
}
