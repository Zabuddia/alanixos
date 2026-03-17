{ pkgs-unstable, ... }:
{
  programs.librewolf = {
    enable = true;
    package = pkgs-unstable.librewolf;

    settings = {
      "browser.toolbars.bookmarks.visibility" = "never";
    };

    policies = {
      Cookies = {
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