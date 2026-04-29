{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.desktop.printing;
in
lib.mkIf cfg.enable {
  services.printing = {
    enable = true;
    browsing = true;
    drivers = with pkgs; [
      brlaser
      gutenprint
      hplip
    ];
    webInterface = true;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  services.ipp-usb.enable = true;

  environment.systemPackages = with pkgs; [
    system-config-printer
  ];
}
