{ config, lib, ... }:

let
  cfg = config.alanix.desktop.gaming;
  inherit (lib) types;
in
{
  options.alanix.desktop.gaming = {
    enable = lib.mkEnableOption "desktop gaming tools";

    enable32BitGraphics = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable 32-bit graphics drivers for Wine/Proton games.";
    };

    enableGameMode = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable GameMode for per-game performance tuning.";
    };

    packages = lib.mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Host-specific gaming packages to install.";
    };

    steam.enable = lib.mkEnableOption "Steam";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.alanix.desktop.enable;
          message = "alanix.desktop.gaming.enable requires alanix.desktop.enable = true.";
        }
      ];

      hardware.graphics.enable = true;

      environment.systemPackages = cfg.packages;
    }

    (lib.mkIf cfg.enable32BitGraphics {
      hardware.graphics.enable32Bit = true;
    })

    (lib.mkIf cfg.enableGameMode {
      programs.gamemode.enable = true;
    })

    (lib.mkIf cfg.steam.enable {
      programs.steam.enable = true;
    })
  ]);
}
