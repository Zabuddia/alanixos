{ pkgs-unstable, ... }:

{
  imports = [ ./programs/git.nix ./programs/sh.nix ./programs/ssh.nix ];

  home.username = "buddia";
  home.homeDirectory = "/home/buddia";
  programs.home-manager.enable = true;
  home.stateVersion = "25.11";

  home.packages = [ pkgs-unstable.yt-dlp ];
}
