{ config, lib, ... }:

lib.mkIf config.alanix.desktop.enable {
  programs.waybar.enable = true;
}
