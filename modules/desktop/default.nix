{ lib, ... }:

{
  imports = [
    ./sway.nix
    ./audio.nix
  ];

  options.alanix.desktop = {
    enable = lib.mkEnableOption "alanix desktop environment";

    autoLogin = {
      enable = lib.mkEnableOption "automatic login (bypass greeter, start Sway at boot)";
      user = lib.mkOption {
        type = lib.types.str;
        description = "User to auto-login as.";
      };
    };
  };
}
