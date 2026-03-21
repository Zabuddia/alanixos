{ lib, pkgs-unstable, ... }:

{
  options.chromium.enable = lib.mkEnableOption "Chromium for this user";

  isEnabled = userCfg: userCfg.chromium.enable;

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.chromium.enable {
      programs.chromium = {
        enable = true;
        package = pkgs-unstable.ungoogled-chromium;
        commandLineArgs = [
          "--ozone-platform=wayland"
          "--disable-features=VaapiVideoDecodeLinuxGL"
          "--homepage=about:blank"
          "--no-default-browser-check"
        ];
      };
    };
}
