{ lib, config, ... }:

let
  cfg = config.alanix.power;
in
{
  options.alanix.power = {
    enable = lib.mkEnableOption "host power management";

    enablePowerProfilesDaemon = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable power-profiles-daemon.";
    };

    enableUpower = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable UPower.";
    };

    enableThermald = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable thermald.";
    };

    enablePowertop = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable PowerTOP auto-tuning.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.power-profiles-daemon.enable = cfg.enablePowerProfilesDaemon;
    services.upower.enable = cfg.enableUpower;
    services.thermald.enable = cfg.enableThermald;
    powerManagement.powertop.enable = cfg.enablePowertop;
  };
}
