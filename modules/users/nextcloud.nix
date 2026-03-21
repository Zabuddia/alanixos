{ lib, ... }:

{
  options.nextcloud.enable = lib.mkEnableOption "Nextcloud client for this user";

  isEnabled = userCfg: userCfg.nextcloud.enable;

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.nextcloud.enable {
      services.nextcloud-client = {
        enable = true;
        startInBackground = true;
      };
    };
}
