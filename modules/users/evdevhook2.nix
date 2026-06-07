{ config, lib, pkgs, ... }:

let
  cfg = config.evdevhook2;
in
{
  options.evdevhook2 = {
    enable = lib.mkEnableOption "evdevhook2 CemuHook/DSU motion server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.evdevhook2;
      description = "evdevhook2 package to install and run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 26760;
      description = "UDP port used by the evdevhook2 DSU server.";
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    ({ config, ... }:
      let
        configFilePath = "${config.xdg.configHome}/evdevhook2/config.ini";
      in
      {
        home.packages = [ cfg.package ];

        xdg.configFile."evdevhook2/config.ini".text = ''
          [Evdevhook]
          Port=${toString cfg.port}
        '';

        systemd.user.services.evdevhook2 = {
          Unit = {
            Description = "evdevhook2 CemuHook/DSU motion server";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArg configFilePath}";
            Restart = "always";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      })
  ];
}
