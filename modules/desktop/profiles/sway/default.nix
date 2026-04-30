{ config, pkgs, lib, ... }:

let
  cfg = config.alanix.desktop;
  swayCfg = cfg.profiles.sway;
  active = cfg.enable && cfg.profile == "sway";
  outputRules = if swayCfg.outputRules == null then [ ] else swayCfg.outputRules;
  createHeadlessOutput = swayCfg.createHeadlessOutput == true;
  inactiveSettingsUsed =
    swayCfg.autoLogin.enable
    || swayCfg.autoLogin.user != null
    || swayCfg.loginKeyring.enable
    || swayCfg.createHeadlessOutput != null
    || swayCfg.outputRules != null
    || swayCfg.idle.lockSeconds != null
    || swayCfg.idle.displayOffSeconds != null
    || swayCfg.idle.suspendSeconds != null;
in
{
  options.alanix.desktop.profiles.sway = {
    autoLogin = {
      enable = lib.mkEnableOption "automatic login (bypass greeter, start Sway at boot)";
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "User to auto-login as.";
      };
    };

    loginKeyring.enable = lib.mkEnableOption "GNOME login keyring integration for the Sway session";

    createHeadlessOutput = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether to create a headless Sway output at session startup.";
    };

    outputRules = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Additional Sway output directives written into /etc/sway/config.d.";
    };

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

  config = lib.mkMerge [
    {
      assertions =
        lib.optionals (!active && inactiveSettingsUsed) [
          {
            assertion = false;
            message = "alanix.desktop.profiles.sway.* is only valid when alanix.desktop.enable = true and alanix.desktop.profile = \"sway\".";
          }
        ]
        ++ lib.optionals (active && swayCfg.autoLogin.enable) [
          {
            assertion = swayCfg.autoLogin.user != null;
            message = "alanix.desktop.profiles.sway.autoLogin.user must be set when alanix.desktop.profiles.sway.autoLogin.enable = true.";
          }
        ]
        ++ lib.optionals (active && swayCfg.idle.lockSeconds != null) [
          {
            assertion = swayCfg.idle.lockSeconds > 0;
            message = "alanix.desktop.profiles.sway.idle.lockSeconds must be greater than 0 when set.";
          }
        ]
        ++ lib.optionals (active && swayCfg.idle.displayOffSeconds != null) [
          {
            assertion = swayCfg.idle.displayOffSeconds > 0;
            message = "alanix.desktop.profiles.sway.idle.displayOffSeconds must be greater than 0 when set.";
          }
        ]
        ++ lib.optionals (active && swayCfg.idle.suspendSeconds != null) [
          {
            assertion = swayCfg.idle.suspendSeconds > 0;
            message = "alanix.desktop.profiles.sway.idle.suspendSeconds must be greater than 0 when set.";
          }
        ]
        ++ lib.optionals (active && swayCfg.idle.lockSeconds != null && swayCfg.idle.displayOffSeconds != null) [
          {
            assertion = swayCfg.idle.displayOffSeconds >= swayCfg.idle.lockSeconds;
            message = "alanix.desktop.profiles.sway.idle.displayOffSeconds must be greater than or equal to alanix.desktop.profiles.sway.idle.lockSeconds.";
          }
        ]
        ++ lib.optionals (active && swayCfg.idle.displayOffSeconds != null && swayCfg.idle.suspendSeconds != null) [
          {
            assertion = swayCfg.idle.suspendSeconds >= swayCfg.idle.displayOffSeconds;
            message = "alanix.desktop.profiles.sway.idle.suspendSeconds must be greater than or equal to alanix.desktop.profiles.sway.idle.displayOffSeconds.";
          }
        ];
    }

    (lib.mkIf active {
      programs.sway.enable = true;
      security.polkit.enable = true;
      services.gnome.gnome-keyring.enable = swayCfg.loginKeyring.enable;

      environment.etc."sway/config.d/10-alanix-output-rules.conf" = lib.mkIf (outputRules != [ ]) {
        text = lib.concatStringsSep "\n" outputRules + "\n";
      };

      environment.etc."sway/config.d/11-alanix-headless-output.conf" = lib.mkIf createHeadlessOutput {
        text = "exec ${pkgs.sway}/bin/swaymsg create_output\n";
      };

      services.greetd = {
        enable = true;
        settings.default_session =
          if swayCfg.autoLogin.enable then {
            command = "${pkgs.sway}/bin/sway";
            user = swayCfg.autoLogin.user;
          } else {
            command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd sway";
            user = "greeter";
          };
      };

      services.gnome.gcr-ssh-agent.enable = false;
      services.udev.packages = [ pkgs.brightnessctl ];
    })
  ];
}
