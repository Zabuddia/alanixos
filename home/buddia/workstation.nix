{ pkgs, pkgs-unstable, ... }:

{
  imports = [ ./common.nix ./programs/librewolf.nix ./programs/codium.nix ./desktop.nix ];

  home.packages = with pkgs; [ xournalpp libreoffice remmina tor-browser ]
    ++ (with pkgs-unstable; [ gimp chromium firefox moonlight-qt ]);
}
