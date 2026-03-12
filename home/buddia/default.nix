{ config, pkgs, ... }:

{
  home.username = "buddia";
  home.homeDirectory = "/home/buddia";

  programs.home-manager.enable = true;

  imports = [
    ./git.nix
    ./sh.nix
  ];

  home.packages = with pkgs; [
    foot
    chromium
  ];

  home.stateVersion = "25.11";
}
