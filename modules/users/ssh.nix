{ lib, ... }:

let
  inherit (lib) types;
in
{
  options = {
    ssh = {
      enable = lib.mkEnableOption "SSH client config for this user";

      matchBlocks = lib.mkOption {
        type = types.attrs;
        default = { };
        description = "Additional Home Manager SSH match blocks.";
      };
    };
  };

  isEnabled = userCfg: userCfg.ssh.enable || userCfg.ssh.matchBlocks != { };

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.ssh.enable {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        matchBlocks =
          {
            "*" = {
              addKeysToAgent = "yes";
              serverAliveInterval = 60;
              serverAliveCountMax = 3;
              controlMaster = "auto";
              controlPath = "~/.ssh/control-%C";
              controlPersist = "10m";
            };
          }
          // userCfg.ssh.matchBlocks;
      };
    };

  assertions = username: userCfg:
    lib.optionals (!userCfg.ssh.enable && userCfg.ssh.matchBlocks != { }) [
      {
        assertion = false;
        message = "alanix.users.accounts.${username}.ssh.matchBlocks requires alanix.users.accounts.${username}.ssh.enable = true.";
      }
    ];
}
