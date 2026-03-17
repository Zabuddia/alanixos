{ lib, ... }:

{
  imports = [
    ./sway.nix
    ./audio.nix
  ];

  options.alanix.desktop.enable = lib.mkEnableOption "alanix desktop environment";
}
