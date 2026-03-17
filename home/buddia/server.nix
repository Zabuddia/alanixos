{ pkgs, ... }:

{
  imports = [ ./common.nix ./programs/chromium.nix ];

  home.packages = with pkgs; [ ];
}
