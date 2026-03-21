{ config, lib, name, ... }:

let
  cfg = config.sh;
  repoPath =
    if config.home.directory != null then
      "${config.home.directory}/.nixos"
    else
      "/home/${name}/.nixos";
in
{
  options.sh.enable = lib.mkEnableOption "bash shell config for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      programs.bash = {
        enable = true;
        shellAliases.nrs = "sudo nixos-rebuild switch --flake path:${repoPath}";
      };
    }
  ];
}
