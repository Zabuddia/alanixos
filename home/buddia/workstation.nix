{ pkgs, ... }:

{
  imports = [ ./common.nix ./programs/librewolf.nix ./programs/codium.nix ];

  home.packages = with pkgs; [
    xournalpp
    libreoffice
    remmina
    gimp
    tor-browser
    chromium
    firefox
  ];
}
