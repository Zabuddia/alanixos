{ pkgs, ... }:
{
  programs.sway.enable = true;

  # Login manager to start sway
  services.greetd.enable = true;
  services.greetd.settings.default_session = {
    command = "${pkgs.greetd.tuigreet}/bin/tuigreet --cmd sway";
    user = "greeter";
  };
}