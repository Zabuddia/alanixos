{ config, lib, ... }:

let
  cfg = config.nextcloudClient;
in
{
  options.nextcloudClient.enable = lib.mkEnableOption "Nextcloud client for this user";

  config.home.modules = lib.optionals cfg.enable [
    {
      services.nextcloud-client = {
        enable = true;
        startInBackground = true;
      };
    }
  ];
}
