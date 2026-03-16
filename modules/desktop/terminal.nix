{ config, pkgs, lib, ... }:

lib.mkIf config.alanix.desktop.enable {
  environment.systemPackages = [ pkgs.foot ];
}
