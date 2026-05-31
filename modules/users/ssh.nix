{ config, lib, name, ... }:

let
  inherit (lib) types;
  cfg = config.ssh;
in
{
  options = {
    ssh = {
      enable = lib.mkEnableOption "SSH client config for this user";

      settings = lib.mkOption {
        type = types.attrs;
        default = { };
        description = "Additional Home Manager SSH settings blocks.";
      };
    };
  };

  config = {
    _assertions = lib.optionals (!cfg.enable && cfg.settings != { }) [
      {
        assertion = false;
        message = "alanix.users.accounts.${name}.ssh.settings requires alanix.users.accounts.${name}.ssh.enable = true.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        programs.ssh = {
          enable = true;
          enableDefaultConfig = false;
          settings =
            {
              "*" = {
                AddKeysToAgent = "yes";
                ServerAliveInterval = 60;
                ServerAliveCountMax = 3;
                ControlMaster = "auto";
                ControlPath = "~/.ssh/control-%C";
                ControlPersist = "10m";
              };
            }
            // cfg.settings;
        };
      }
    ];
  };
}
