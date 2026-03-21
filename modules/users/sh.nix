{ lib, ... }:

{
  options.sh.enable = lib.mkEnableOption "bash shell config for this user";

  isEnabled = userCfg: userCfg.sh.enable;

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.sh.enable {
      programs.bash = {
        enable = true;
        shellAliases.nrs = "sudo nixos-rebuild switch --flake path:/home/buddia/.nixos";
      };
    };
}
