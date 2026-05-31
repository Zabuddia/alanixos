{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.vscode;
in
{
  options.vscode.enable = lib.mkEnableOption "VSCodium for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      programs.vscodium = {
        enable = true;
        profiles.default.extensions = with pkgs-unstable.vscode-extensions; [
          jnoortheen.nix-ide
          yzhang.markdown-all-in-one
        ];
      };
    }
  ];
}
