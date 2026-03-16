{ pkgs, ... }:
{
  programs.git = {
    enable = true;

    settings = {
      github.user = "zabuddia";
      user.name  = "Alan Fife";
      user.email = "fife.alan@protonmail.com";

      init.defaultBranch = "main";
    };
  };
}