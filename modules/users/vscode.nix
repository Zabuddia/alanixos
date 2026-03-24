{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.vscode;
in
{
  options.vscode.enable = lib.mkEnableOption "VSCodium for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      programs.vscode = {
        enable = true;
        package = pkgs-unstable.vscodium;
        profiles.default.extensions = with pkgs-unstable.vscode-extensions; [
          jnoortheen.nix-ide
          yzhang.markdown-all-in-one
        ];
      };
    }
  ];
}
