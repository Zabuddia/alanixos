{ config, lib, pkgs, ... }:

lib.mkIf config.alanix.desktop.enable {
  environment.systemPackages = [ pkgs.alsa-utils ];

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
}
