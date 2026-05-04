{ lib, config, ... }:

let
  cfg = config.alanix.power;
  sleepActionType = lib.types.enum [
    "ignore"
    "poweroff"
    "reboot"
    "halt"
    "kexec"
    "suspend"
    "hibernate"
    "hybrid-sleep"
    "suspend-then-hibernate"
    "sleep"
    "lock"
  ];
  manualHibernateResume =
    cfg.hibernate.resumeDevice != null || cfg.hibernate.resumeOffset != null;
in
{
  options.alanix.power = {
    enable = lib.mkEnableOption "host power management";

    enablePowerProfilesDaemon = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable power-profiles-daemon.";
    };

    enableUpower = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable UPower.";
    };

    enableThermald = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable thermald.";
    };

    enablePowertop = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable PowerTOP auto-tuning.";
    };

    lidSwitch = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to configure systemd-logind lid switch handling.";
      };

      action = lib.mkOption {
        type = sleepActionType;
        default = "suspend";
        description = "Action to take when the lid is closed on battery.";
      };

      externalPowerAction = lib.mkOption {
        type = sleepActionType;
        default = "suspend";
        description = "Action to take when the lid is closed on external power.";
      };

      dockedAction = lib.mkOption {
        type = sleepActionType;
        default = "ignore";
        description = "Action to take when the lid is closed while docked or using an external display.";
      };
    };

    hibernate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to configure hibernation support.";
      };

      autoResume = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to use systemd initrd and systemd's automatic hibernate resume location.";
      };

      resumeDevice = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Manual hibernate resume device for swapfile-backed hibernation.";
      };

      resumeOffset = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Manual hibernate resume offset for swapfile-backed hibernation.";
      };

      suspendThenHibernateDelay = lib.mkOption {
        type = lib.types.str;
        default = "30min";
        description = "Time to remain suspended before hibernating.";
      };

      hibernateOnACPower = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether suspend-then-hibernate should hibernate while on external power.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            !cfg.hibernate.enable
            || cfg.hibernate.autoResume
            || (cfg.hibernate.resumeDevice != null && cfg.hibernate.resumeOffset != null);
          message = "alanix.power.hibernate requires autoResume = true or both resumeDevice and resumeOffset.";
        }
        {
          assertion =
            !manualHibernateResume
            || (cfg.hibernate.resumeDevice != null && cfg.hibernate.resumeOffset != null);
          message = "alanix.power.hibernate resumeDevice and resumeOffset must be set together.";
        }
      ];

      services.power-profiles-daemon.enable = cfg.enablePowerProfilesDaemon;
      services.upower.enable = cfg.enableUpower;
      services.thermald.enable = cfg.enableThermald;
      powerManagement.powertop.enable = cfg.enablePowertop;
    }

    (lib.mkIf cfg.lidSwitch.enable {
      services.logind.settings.Login = {
        HandleLidSwitch = cfg.lidSwitch.action;
        HandleLidSwitchExternalPower = cfg.lidSwitch.externalPowerAction;
        HandleLidSwitchDocked = cfg.lidSwitch.dockedAction;
      };
    })

    (lib.mkIf cfg.hibernate.enable {
      boot.initrd.systemd.enable = lib.mkIf cfg.hibernate.autoResume true;
      boot.resumeDevice = lib.mkIf (cfg.hibernate.resumeDevice != null) cfg.hibernate.resumeDevice;
      boot.kernelParams =
        lib.mkIf (cfg.hibernate.resumeOffset != null)
          [ "resume_offset=${toString cfg.hibernate.resumeOffset}" ];
      systemd.sleep.extraConfig = ''
        HibernateDelaySec=${cfg.hibernate.suspendThenHibernateDelay}
        HibernateOnACPower=${if cfg.hibernate.hibernateOnACPower then "yes" else "no"}
      '';
    })
  ]);
}
