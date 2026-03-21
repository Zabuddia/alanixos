{ config, pkgs, lib, ... }:

lib.mkIf config.alanix.desktop.enable {
  programs.sway.enable = true;
  security.polkit.enable = true;

  environment.etc."sway/config.d/10-alanix-output-rules.conf" = lib.mkIf (config.alanix.desktop.swayOutputRules != [ ]) {
    text = lib.concatStringsSep "\n" config.alanix.desktop.swayOutputRules + "\n";
  };

  services.greetd = {
    enable = true;
    settings.default_session =
      if config.alanix.desktop.autoLogin.enable then {
        command = "${pkgs.sway}/bin/sway";
        user = config.alanix.desktop.autoLogin.user;
      } else {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd sway";
        user = "greeter";
      };
  };

  services.gnome.gcr-ssh-agent.enable = false;
  services.udev.packages = [ pkgs.brightnessctl ];
}
