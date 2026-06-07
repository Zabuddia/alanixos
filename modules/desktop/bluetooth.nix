{ config, lib, ... }:

let
  cfg = config.alanix.desktop.bluetooth;
in
lib.mkIf cfg.enable {
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = cfg.powerOnBoot;
  } // lib.optionalAttrs cfg.allowUnbondedClassicHid {
    input.General.ClassicBondedOnly = false;
  };

  services.blueman.enable = true;
}
