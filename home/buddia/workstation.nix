{ pkgs, pkgs-unstable, ... }:

{
  imports = [ ./common.nix ./programs/librewolf.nix ./programs/codium.nix ./programs/chromium.nix ./desktop.nix ];

  home.packages = with pkgs; [ xournalpp libreoffice remmina tor-browser ]
    ++ (with pkgs-unstable; [ gimp firefox moonlight-qt ]);
}
