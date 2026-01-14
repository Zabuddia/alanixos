{ config, pkgs, ... }:

{
  home.username = "buddia";
  home.homeDirectory = "/home/buddia";

  programs.home-manager.enable = true;

  imports = [
    ./git.nix
  ];

  home.stateVersion = "25.11";
}
