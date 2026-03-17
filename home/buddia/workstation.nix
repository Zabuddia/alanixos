{ pkgs, ... }:

{
  imports = [ ./common.nix ./programs/librewolf.nix ./programs/codium.nix ./desktop.nix ];

  home.packages = with pkgs; [
    xournalpp
    libreoffice
    remmina
    gimp
    tor-browser
    chromium
    firefox
    moonlight-qt
  ];
}
