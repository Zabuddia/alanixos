{ config, lib, pkgs, ... }:

let
  inherit (lib) types;

  cfg = config.kodi;

  hasTvheadend = cfg.tvheadend.servers != [ ];

  kodiPackage =
    if hasTvheadend
    then cfg.package.withPackages (p: [ p.pvr-hts ])
    else cfg.package;

  tvheadendSettingsXml = server: ''
    <settings version="2">
        <setting id="host">${server.host}</setting>
        <setting id="htsp_port">${toString server.htspPort}</setting>
        <setting id="http_port">${toString server.httpPort}</setting>
    </settings>
  '';

  # pvr.hts multi-instance: index 0 → settings.xml, index N>0 → instance-settings-N.xml
  tvheadendFiles = builtins.listToAttrs (lib.imap0
    (i: server: {
      name = ".kodi/userdata/addon_data/pvr.hts/${
        if i == 0 then "settings.xml" else "instance-settings-${toString i}.xml"
      }";
      value.text = tvheadendSettingsXml server;
    })
    cfg.tvheadend.servers);
in
{
  options.kodi = {
    enable = lib.mkEnableOption "Kodi for this user";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.kodi-wayland;
      description = "Kodi package to install.";
    };

    tvheadend = {
      servers = lib.mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = lib.mkOption {
              type = types.str;
              description = "Display name for this TVHeadend server.";
            };

            host = lib.mkOption {
              type = types.str;
              description = "Hostname or IP address of the TVHeadend server.";
            };

            htspPort = lib.mkOption {
              type = types.int;
              default = 9982;
              description = "HTSP port used by Kodi to stream live TV and recordings.";
            };

            httpPort = lib.mkOption {
              type = types.int;
              default = 9981;
              description = "HTTP port used by the TVHeadend web interface.";
            };
          };
        });
        default = [ ];
        description = "List of TVHeadend servers to configure. The first entry is the primary instance; additional entries create multi-instance pvr.hts configs.";
      };
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    {
      home.packages = [ kodiPackage ];
      home.file = lib.optionalAttrs hasTvheadend tvheadendFiles;
    }
  ];
}
