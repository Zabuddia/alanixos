{ lib, ... }:

let
  profileRoot = ./profiles;
  profiles = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir profileRoot)
  );
in

{
  imports = map (profile: profileRoot + "/${profile}") profiles ++ [
    ./storage.nix
    ./audio.nix
    ./bluetooth.nix
    ./flatpak.nix
    ./fingerprint.nix
    ./printing.nix
  ];

  options.alanix.desktop = {
    enable = lib.mkEnableOption "alanix desktop environment";

    profile = lib.mkOption {
      type = lib.types.enum profiles;
      default = "sway";
      description = "Desktop profile to enable for this host.";
    };

    bluetooth = {
      enable = lib.mkEnableOption "Bluetooth support for desktop hosts";

      powerOnBoot = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to power on the Bluetooth controller during boot.";
      };
    };

    fingerprint.enable = lib.mkEnableOption "fingerprint authentication for screen lock and sudo";

    printing.enable = lib.mkEnableOption "printing support for desktop hosts";
  };
}
