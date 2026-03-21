{ lib, pkgs-unstable, ... }:

{
  options.vscode.enable = lib.mkEnableOption "VSCodium for this user";

  isEnabled = userCfg: userCfg.vscode.enable;

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.vscode.enable {
      programs.vscode = {
        enable = true;
        package = pkgs-unstable.vscodium;
        profiles.default.extensions = with pkgs-unstable.vscode-extensions; [
          ms-vscode-remote.remote-ssh
          jnoortheen.nix-ide
        ];
      };
    };
}
