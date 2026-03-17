{ pkgs, ... }:

{
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
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
