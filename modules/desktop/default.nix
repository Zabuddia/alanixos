{ lib, ... }:

{
  imports = [
    ./sway.nix
    ./waybar.nix
    ./terminal.nix
    ./launcher.nix
  ];

  options.alanix.desktop.enable = lib.mkEnableOption "alanix desktop environment";
}
