{ config, lib, pkgs, ... }:

let
  inherit (lib) types;

  cfg = config.kodi;

  hasTvheadend = cfg.tvheadend.servers != [ ];

  kodiPackage = cfg.package.withPackages (p:
    [ p.joystick ]
    ++ lib.optionals hasTvheadend [ p.pvr-hts ]);

  tvheadendSettingsXml = server: ''
    <settings version="2">
        <setting id="kodi_addon_instance_name">${server.name}</setting>
        <setting id="kodi_addon_instance_enabled" default="true">true</setting>
        <setting id="host">${server.host}</setting>
        <setting id="htsp_port">${toString server.htspPort}</setting>
        <setting id="http_port">${toString server.httpPort}</setting>
    </settings>
  '';

  # pvr.hts uses instance-settings-N.xml starting at 1 for all instances
  tvheadendFiles = builtins.listToAttrs (lib.imap1
    (i: server: {
      name = ".kodi/userdata/addon_data/pvr.hts/instance-settings-${toString i}.xml";
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
    ({ config, lib, ... }: {
      home.packages = [ kodiPackage ];
      home.file = lib.optionalAttrs hasTvheadend tvheadendFiles;

      home.activation.enableKodiTvheadendPvr = lib.mkIf hasTvheadend (lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        db="${config.home.homeDirectory}/.kodi/userdata/Database/Addons33.db"
        if [ -f "$db" ] && [ "$(${pkgs.sqlite}/bin/sqlite3 "$db" "select count(*) from sqlite_master where type = 'table' and name = 'installed';")" = "1" ]; then
          if ! ${pkgs.sqlite}/bin/sqlite3 "$db" "update installed set enabled = 1, disabledReason = 0 where addonID = 'pvr.hts';"; then
            echo "warning: could not enable Kodi pvr.hts in $db; Kodi may be running" >&2
          fi
        fi
      '');
    })
  ];
}
