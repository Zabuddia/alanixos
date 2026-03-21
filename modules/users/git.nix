{ lib, ... }:

let
  inherit (lib) types;
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

  isEnabled = userCfg: userCfg.git.enable;

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.git.enable {
      programs.git = {
        enable = true;
        settings = lib.recursiveUpdate {
          github.user = userCfg.git.github.user;
          user.name = userCfg.git.user.name;
          user.email = userCfg.git.user.email;
          init.defaultBranch = userCfg.git.init.defaultBranch;
        } userCfg.git.extraSettings;
      };
    };

  assertions = username: userCfg:
    lib.optionals userCfg.git.enable [
      {
        assertion = userCfg.git.github.user != null;
        message = "alanix.users.accounts.${username}.git.github.user must be set when git is enabled.";
      }
      {
        assertion = userCfg.git.user.name != null;
        message = "alanix.users.accounts.${username}.git.user.name must be set when git is enabled.";
      }
      {
        assertion = userCfg.git.user.email != null;
        message = "alanix.users.accounts.${username}.git.user.email must be set when git is enabled.";
      }
      {
        assertion = userCfg.git.init.defaultBranch != null;
        message = "alanix.users.accounts.${username}.git.init.defaultBranch must be set when git is enabled.";
      }
    ];
}
