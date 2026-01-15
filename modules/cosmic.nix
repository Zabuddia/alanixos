{ pkgs, ... }:
{
  services.desktopManager.cosmic.enable = true;
  services.displayManager.cosmic-greeter.enable = true;

  # Strip "extra apps" that COSMIC would otherwise pull in
  environment.cosmic.excludePackages = with pkgs; [
    cosmic-term
    cosmic-files
    cosmic-edit
    cosmic-player
    cosmic-screenshot
  ];
}
