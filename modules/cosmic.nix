{ pkgs, ... }:
{
  services.desktopManager.cosmic.enable = true;
  services.displayManager.cosmic-greeter.enable = true;

  # Prevent GNOME’s SSH agent from conflicting with OpenSSH agent
  services.gnome.gcr-ssh-agent.enable = false;
}
