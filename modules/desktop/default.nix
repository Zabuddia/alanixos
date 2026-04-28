{ config, lib, ... }:

let
  cfg = config.alanix.desktop;
in

{
  imports = [
    ./sway.nix
    ./storage.nix
    ./audio.nix
    ./bluetooth.nix
    ./flatpak.nix
    ./fingerprint.nix
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

    loginKeyring.enable = lib.mkEnableOption "GNOME login keyring integration";

    createHeadlessOutput = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to create a headless Sway output at session startup.";
    };

    bluetooth = {
      enable = lib.mkEnableOption "Bluetooth support for desktop hosts";

      powerOnBoot = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to power on the Bluetooth controller during boot.";
      };
    };

    swayOutputRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Sway output directives written into /etc/sway/config.d.";
    };

    fingerprint.enable = lib.mkEnableOption "fingerprint authentication for screen lock and sudo";

    idle = {
      lockSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Seconds before the session locks.";
      };

      displayOffSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Seconds before Sway powers off the display.";
      };

      suspendSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Seconds before suspending the system.";
      };
    };
  };

  config.assertions =
    lib.optionals (cfg.enable && cfg.autoLogin.enable) [
      {
        assertion = cfg.autoLogin.user != null;
        message = "alanix.desktop.autoLogin.user must be set when alanix.desktop.autoLogin.enable = true.";
      }
    ]
    ++ lib.optionals (cfg.idle.lockSeconds != null) [
      {
        assertion = cfg.idle.lockSeconds > 0;
        message = "alanix.desktop.idle.lockSeconds must be greater than 0 when set.";
      }
    ]
    ++ lib.optionals (cfg.idle.displayOffSeconds != null) [
      {
        assertion = cfg.idle.displayOffSeconds > 0;
        message = "alanix.desktop.idle.displayOffSeconds must be greater than 0 when set.";
      }
    ]
    ++ lib.optionals (cfg.idle.suspendSeconds != null) [
      {
        assertion = cfg.idle.suspendSeconds > 0;
        message = "alanix.desktop.idle.suspendSeconds must be greater than 0 when set.";
      }
    ]
    ++ lib.optionals (cfg.idle.lockSeconds != null && cfg.idle.displayOffSeconds != null) [
      {
        assertion = cfg.idle.displayOffSeconds >= cfg.idle.lockSeconds;
        message = "alanix.desktop.idle.displayOffSeconds must be greater than or equal to alanix.desktop.idle.lockSeconds.";
      }
    ]
    ++ lib.optionals (cfg.idle.displayOffSeconds != null && cfg.idle.suspendSeconds != null) [
      {
        assertion = cfg.idle.suspendSeconds >= cfg.idle.displayOffSeconds;
        message = "alanix.desktop.idle.suspendSeconds must be greater than or equal to alanix.desktop.idle.displayOffSeconds.";
      }
    ];
}
