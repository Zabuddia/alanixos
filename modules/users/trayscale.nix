{ lib, pkgs, ... }:

{
  options.trayscale.enable = lib.mkEnableOption "Trayscale tray applet for this user";

  isEnabled = userCfg: userCfg.trayscale.enable;

  homeConfig = _username: userCfg:
    lib.mkIf userCfg.trayscale.enable {
      home.packages = [ pkgs.trayscale ];

      systemd.user.services.trayscale = {
        Unit = {
          Description = "Trayscale tray applet";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${pkgs.trayscale}/bin/trayscale --hide-window";
          Restart = "on-failure";
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
}
