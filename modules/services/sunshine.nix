# Access with http://localhost:47990
{ config, lib, ... }:

let
  cfg = config.alanix.sunshine;
in
{
  options.alanix.sunshine = {
    enable = lib.mkEnableOption "Sunshine game streaming";

    autoStart = lib.mkOption {
      type = lib.types.bool;
      description = "Whether Sunshine should auto-start.";
    };

    capSysAdmin = lib.mkOption {
      type = lib.types.bool;
      description = "Whether Sunshine should request CAP_SYS_ADMIN.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.alanix.desktop.enable;
        message = "alanix.sunshine: requires alanix.desktop.enable = true.";
      }
    ];

    services.sunshine = {
      enable = true;
      inherit (cfg) autoStart capSysAdmin;
    };
  };
}
