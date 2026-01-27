{ config, pkgs, ... }:

{
  programs.bash.enable = true;
  programs.bash.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake path:/home/buddia/.nixos";
  };
}