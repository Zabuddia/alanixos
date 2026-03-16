{ config, pkgs, lib, ... }:

lib.mkIf config.alanix.desktop.enable {
  programs.sway.enable = true;
  security.polkit.enable = true;

  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd sway";
      user = "greeter";
    };
  };

  services.gnome.gcr-ssh-agent.enable = false;
}
