{ config, lib, ... }:

let
  cfg = config.alanix.desktop;
in
{
  config = lib.mkIf (cfg.enable && cfg.profile == "gnome") {
    security.polkit.enable = true;
    programs.dconf.enable = true;
    services.desktopManager.gnome.enable = true;
    services.displayManager.gdm.enable = true;
    services.gnome.gcr-ssh-agent.enable = lib.mkForce false;
    services.gnome.gnome-keyring.enable = true;
  };
}
