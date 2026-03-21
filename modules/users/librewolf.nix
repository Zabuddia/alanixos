{ lib, pkgs-unstable, ... }:

{
  options.librewolf.enable = lib.mkEnableOption "LibreWolf for this user";

  isEnabled = userCfg: userCfg.librewolf.enable;

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.librewolf.enable {
      programs.librewolf = {
        enable = true;
        package = pkgs-unstable.librewolf;
        settings."browser.toolbars.bookmarks.visibility" = "never";
        policies.Cookies = {
          Behavior = "reject";
          Allow = [
            "https://chatgpt.com"
            "https://github.com"
            "https://tailscale.com"
            "https://chess.com"
          ];
        };
      };
    };
}
