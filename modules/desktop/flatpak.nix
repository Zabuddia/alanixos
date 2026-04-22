{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.alanix.desktop.flatpak;
  hasPackages = cfg.packages != [ ];
  packageAppId =
    package:
    if builtins.isString package then
      package
    else if builtins.isAttrs package && package ? appId then
      package.appId
    else
      null;
  appIds = builtins.filter (appId: appId != null) (map packageAppId cfg.packages);
  wrapperName = appId: lib.toLower (lib.last (lib.splitString "." appId));
  wrapperNames = map wrapperName appIds;
  flatpakWrappers =
    map
      (appId:
        pkgs.writeShellScriptBin (wrapperName appId) ''
          exec ${config.services.flatpak.package}/bin/flatpak run --system ${lib.escapeShellArg appId} "$@"
        '')
      appIds;
in
{
  imports = [
    inputs.nix-flatpak.nixosModules.nix-flatpak
  ];

  options.alanix.desktop.flatpak = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
      description = "System-wide Flatpak apps to install from Flathub.";
      example = [
        "app.openbubbles.OpenBubbles"
      ];
    };
  };

  config = lib.mkIf hasPackages {
    assertions = [
      {
        assertion = config.alanix.desktop.enable;
        message = "alanix.desktop.flatpak.packages requires alanix.desktop.enable = true.";
      }
      {
        assertion = wrapperNames == lib.unique wrapperNames;
        message = "alanix.desktop.flatpak.packages generates duplicate command wrappers.";
      }
    ];

    environment.systemPackages = flatpakWrappers;

    services.flatpak = {
      enable = true;
      remotes = [
        {
          name = "flathub";
          location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
        }
      ];
      packages = cfg.packages;
      update.auto = {
        enable = true;
        onCalendar = "weekly";
      };
      uninstallUnmanaged = false;
      uninstallUnused = false;
    };
  };
}
