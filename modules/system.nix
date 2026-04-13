{ hostname, lib, config, ... }:

let
  cfg = config.alanix.system;
  inherit (lib) types;
in
{
  options.alanix.system = {
    stateVersion = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "NixOS state version for this host.";
    };

    timeZone = lib.mkOption {
      type = types.str;
      default = "America/Denver";
      description = "System time zone.";
    };

    locale = lib.mkOption {
      type = types.str;
      default = "en_US.UTF-8";
      description = "Default locale.";
    };

    enableSystemdBoot = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable the systemd-boot bootloader.";
    };

    canTouchEfiVariables = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether the bootloader may update EFI variables.";
    };

    allowUnfree = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether unfree packages are allowed.";
    };

    experimentalFeatures = lib.mkOption {
      type = types.listOf types.str;
      default = [ "nix-command" "flakes" ];
      description = "Enabled Nix experimental features.";
    };

    enableNixLd = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable nix-ld.";
    };

    enableNetworkManager = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable NetworkManager.";
    };

    enableFirewall = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable the NixOS firewall.";
    };

    packages = lib.mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Base system packages for this host.";
    };

    swapDevices = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          device = lib.mkOption {
            type = types.str;
            description = "Swap device path.";
          };

          size = lib.mkOption {
            type = types.int;
            description = "Swap size in MiB.";
          };
        };
      });
      default = [ ];
      description = "Swap devices configured for this host.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.stateVersion != null;
          message = "alanix.system.stateVersion must be set.";
        }
      ];

      networking.hostName = hostname;
      time.timeZone = cfg.timeZone;

      boot.loader.systemd-boot.enable = cfg.enableSystemdBoot;
      boot.loader.efi.canTouchEfiVariables = cfg.canTouchEfiVariables;

      i18n.defaultLocale = cfg.locale;

      nixpkgs.config.allowUnfree = cfg.allowUnfree;
      nix.settings.experimental-features = cfg.experimentalFeatures;
      nix.settings.download-buffer-size = 524288000; # 500 MiB
      programs.nix-ld.enable = cfg.enableNixLd;

      networking.networkmanager.enable = cfg.enableNetworkManager;
      networking.firewall.enable = cfg.enableFirewall;

      environment.systemPackages = cfg.packages;
      swapDevices = cfg.swapDevices;
    }

    (lib.mkIf (cfg.stateVersion != null) {
      system.stateVersion = cfg.stateVersion;
    })
  ];
}
