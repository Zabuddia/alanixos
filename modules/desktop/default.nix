{ config, lib, ... }:

let
  cfg = config.alanix.desktop;
in

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
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "User to auto-login as.";
      };
    };
  };

  config.assertions = lib.optionals (cfg.enable && cfg.autoLogin.enable) [
    {
      assertion = cfg.autoLogin.user != null;
      message = "alanix.desktop.autoLogin.user must be set when alanix.desktop.autoLogin.enable = true.";
    }
  ];
}
