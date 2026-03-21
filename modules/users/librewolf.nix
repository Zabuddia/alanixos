{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.librewolf;
in
{
  options.librewolf.enable = lib.mkEnableOption "LibreWolf for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
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
    }
  ];
}
