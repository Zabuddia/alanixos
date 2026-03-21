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
      default = true;
      description = "Whether Sunshine should auto-start.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the firewall for Sunshine.";
    };

    capSysAdmin = lib.mkOption {
      type = lib.types.bool;
      default = false;
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
      inherit (cfg) autoStart openFirewall capSysAdmin;
    };
  };
}
