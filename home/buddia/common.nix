{ ... }:

{
  imports = [ ./programs/git.nix ./programs/sh.nix ];

  home.username = "buddia";
  home.homeDirectory = "/home/buddia";
  programs.home-manager.enable = true;
  home.stateVersion = "25.11";
}
