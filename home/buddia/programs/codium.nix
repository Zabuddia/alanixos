{ pkgs, pkgs-unstable, ... }:

{
  programs.vscode = {
    enable = true;
    package = pkgs-unstable.vscodium;
    profiles.default.extensions = with pkgs-unstable.vscode-extensions; [
      ms-vscode-remote.remote-ssh
      jnoortheen.nix-ide
    ];
  };
}
