{ config, lib, name, ... }:

let
  inherit (lib) types;
  cfg = config.git;
in
{
  options = {
    git = {
      enable = lib.mkEnableOption "Git for this user";

      github.user = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "GitHub username for git config.";
      };

      user.name = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Git author name.";
      };

      user.email = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Git author email.";
      };

      init.defaultBranch = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default branch name for new repositories.";
      };

      extraSettings = lib.mkOption {
        type = types.attrs;
        default = { };
        description = "Additional git settings merged into programs.git.settings.";
      };
    };
  };

  config = {
    _assertions = lib.optionals cfg.enable [
      {
        assertion = cfg.github.user != null;
        message = "alanix.users.accounts.${name}.git.github.user must be set when git is enabled.";
      }
      {
        assertion = cfg.user.name != null;
        message = "alanix.users.accounts.${name}.git.user.name must be set when git is enabled.";
      }
      {
        assertion = cfg.user.email != null;
        message = "alanix.users.accounts.${name}.git.user.email must be set when git is enabled.";
      }
      {
        assertion = cfg.init.defaultBranch != null;
        message = "alanix.users.accounts.${name}.git.init.defaultBranch must be set when git is enabled.";
      }
    ];

    home.modules = lib.optionals cfg.enable [
      {
        programs.git = {
          enable = true;
          settings = lib.recursiveUpdate {
            github.user = cfg.github.user;
            user.name = cfg.user.name;
            user.email = cfg.user.email;
            init.defaultBranch = cfg.init.defaultBranch;
          } cfg.extraSettings;
        };
      }
    ];
  };
}
