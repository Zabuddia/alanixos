{ config, lib, name, ... }:

let
  inherit (lib) types;
  cfg = config.ssh;
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

  config = {
    _assertions = lib.optionals (!cfg.enable && cfg.matchBlocks != { }) [
      {
        assertion = false;
        message = "alanix.users.accounts.${name}.ssh.matchBlocks requires alanix.users.accounts.${name}.ssh.enable = true.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
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
            // cfg.matchBlocks;
        };
      }
    ];
  };
}
