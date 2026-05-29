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

  config.home.modules = lib.optionals cfg.enable [
    {
      home.packages = [ pkgs-unstable.makemkv ];

      home.file.".MakeMKV/settings.conf" = lib.mkIf (cfg.betaKey != null) {
        text = ''
          app_Key = "${cfg.betaKey}"
        '';
      };
    }
  ];
}
