{ hostname, lib, config, ... }:

let
  cfg = config.alanix.system;
  inherit (lib) types;
in
{
  options.alanix.system = {
    stateVersion = lib.mkOption {
      type = types.str;
      description = "NixOS state version for this host.";
    };

    timeZone = lib.mkOption {
      type = types.str;
      description = "System time zone.";
    };

    locale = lib.mkOption {
      type = types.str;
      description = "Default locale.";
    };

    enableSystemdBoot = lib.mkOption {
      type = types.bool;
      description = "Whether to enable the systemd-boot bootloader.";
    };

    canTouchEfiVariables = lib.mkOption {
      type = types.bool;
      description = "Whether the bootloader may update EFI variables.";
    };

    allowUnfree = lib.mkOption {
      type = types.bool;
      description = "Whether unfree packages are allowed.";
    };

    experimentalFeatures = lib.mkOption {
      type = types.listOf types.str;
      description = "Enabled Nix experimental features.";
    };

    enableNixLd = lib.mkOption {
      type = types.bool;
      description = "Whether to enable nix-ld.";
    };

    enableNetworkManager = lib.mkOption {
      type = types.bool;
      description = "Whether to enable NetworkManager.";
    };

    enableFirewall = lib.mkOption {
      type = types.bool;
      description = "Whether to enable the NixOS firewall.";
    };

    packages = lib.mkOption {
      type = types.listOf types.package;
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

  config = {
    networking.hostName = hostname;
    time.timeZone = cfg.timeZone;
    system.stateVersion = cfg.stateVersion;

    boot.loader.systemd-boot.enable = cfg.enableSystemdBoot;
    boot.loader.efi.canTouchEfiVariables = cfg.canTouchEfiVariables;

    i18n.defaultLocale = cfg.locale;

    nixpkgs.config.allowUnfree = cfg.allowUnfree;
    nix.settings.experimental-features = cfg.experimentalFeatures;
    programs.nix-ld.enable = cfg.enableNixLd;

    networking.networkmanager.enable = cfg.enableNetworkManager;
    networking.firewall.enable = cfg.enableFirewall;

    environment.systemPackages = cfg.packages;
    swapDevices = cfg.swapDevices;
  };
}
