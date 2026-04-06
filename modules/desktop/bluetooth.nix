{ config, lib, ... }:

let
  cfg = config.alanix.desktop.bluetooth;
in
lib.mkIf cfg.enable {
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = cfg.powerOnBoot;
  };

  services.blueman.enable = true;
}
