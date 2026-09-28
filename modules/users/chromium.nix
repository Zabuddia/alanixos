{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.chromium;
in
{
  options.chromium = {
    enable = lib.mkEnableOption "Chromium for this user";
    widevine.enable = lib.mkEnableOption "Widevine DRM support in Chromium";
  };

  config.home.modules = lib.optionals cfg.enable [
    {
      programs.chromium = {
        enable = true;
        package = pkgs-unstable.ungoogled-chromium.override {
          enableWideVine = cfg.widevine.enable;
        };
        commandLineArgs = [
          "--ozone-platform=wayland"
          "--disable-features=VaapiVideoDecodeLinuxGL"
          "--homepage=about:blank"
          "--no-default-browser-check"
        ];
      };
    }
  ];
}
