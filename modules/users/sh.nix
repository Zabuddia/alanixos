{ config, lib, ... }:

let
  cfg = config.sh;
in
{
  options.sh.enable = lib.mkEnableOption "bash shell config for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      programs.bash = {
        enable = true;
        shellAliases.nrs = "sudo nixos-rebuild switch --flake path:/home/buddia/.nixos";
      };
    }
  ];
}
