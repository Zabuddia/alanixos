{ config, pkgs, lib, ... }:

lib.mkIf config.alanix.desktop.enable {
  services.gvfs.enable = true;

  programs.thunar = {
    enable = true;
    plugins = [ pkgs.xfce.thunar-volman ];
  };
}
