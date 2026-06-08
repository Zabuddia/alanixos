{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.desktop.bluetooth;
  joycondWithoutProControllers = pkgs.joycond.overrideAttrs (oldAttrs: {
    installPhase = (oldAttrs.installPhase or "") + ''
      # Let applications use Pro Controllers directly while joycond combines Joy-Cons.
      sed -i '/2009/d' "$out/etc/udev/rules.d/72-joycond.rules"
      sed -i '/2009/d' "$out/etc/udev/rules.d/89-joycond.rules"
    '';
  });
in
lib.mkIf cfg.enable (lib.mkMerge [
  {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = cfg.powerOnBoot;
    } // lib.optionalAttrs cfg.allowUnbondedClassicHid {
      input.General.ClassicBondedOnly = false;
    };

    services.blueman.enable = true;
  }

  (lib.mkIf config.services.joycond.enable {
    services.joycond.package = joycondWithoutProControllers;
  })
])
