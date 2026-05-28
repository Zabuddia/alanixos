{ config, lib, pkgs, ... }:

let
  inherit (lib) types;

  cfg = config.kodi;

  hasTvheadend = cfg.tvheadend.servers != [ ];
  hasInvidious = cfg.invidious.enable;

  kodiPackage = cfg.package.withPackages (p:
    [ p.joystick ]
    ++ lib.optionals hasTvheadend [ p.pvr-hts ]
    ++ lib.optionals hasInvidious [ p.invidious ]);

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

  invidiousSettingsXml = ''
    <settings version="2">
        <setting id="auto_instance">false</setting>
        <setting id="instance_url">${lib.escapeXML cfg.invidious.instanceUrl}</setting>
    </settings>
  '';

  hasMediaSources = cfg.mediaSources.video != [ ] || cfg.mediaSources.music != [ ];
  enabledAddonIds =
    lib.optionals hasTvheadend [ "pvr.hts" ]
    ++ lib.optionals hasInvidious [ "plugin.video.invidious" ];

  withTrailingSlash = path:
    if lib.hasSuffix "/" path then path else "${path}/";

  sourceXml = source: ''
    <source>
        <name>${lib.escapeXML source.name}</name>
        <path pathversion="1">${lib.escapeXML (withTrailingSlash source.path)}</path>
        <allowsharing>true</allowsharing>
    </source>
  '';

  sourcesXml = ''
    <sources>
        <programs>
            <default pathversion="1"></default>
        </programs>
        <video>
            <default pathversion="1"></default>
    ${lib.concatMapStrings sourceXml cfg.mediaSources.video}
        </video>
        <music>
            <default pathversion="1"></default>
    ${lib.concatMapStrings sourceXml cfg.mediaSources.music}
        </music>
        <pictures>
            <default pathversion="1"></default>
        </pictures>
        <files>
            <default pathversion="1"></default>
        </files>
    </sources>
  '';

  mediaSourceType = types.submodule {
    options = {
      name = lib.mkOption {
        type = types.str;
        description = "Display name shown in Kodi.";
      };

      path = lib.mkOption {
        type = types.str;
        description = "Filesystem path Kodi should use for this media source.";
      };
    };
  };
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

    invidious = {
      enable = lib.mkEnableOption "Invidious Kodi add-on";

      instanceUrl = lib.mkOption {
        type = types.str;
        default = "https://invidious.fifefin.com";
        description = "Invidious instance URL used by the Kodi add-on.";
      };
    };

    mediaSources = {
      video = lib.mkOption {
        type = types.listOf mediaSourceType;
        default = [ ];
        description = "Video file sources declared in Kodi sources.xml.";
      };

      music = lib.mkOption {
        type = types.listOf mediaSourceType;
        default = [ ];
        description = "Music file sources declared in Kodi sources.xml.";
      };
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ kodiPackage ];
      home.file =
        lib.optionalAttrs hasTvheadend tvheadendFiles
        // lib.optionalAttrs hasInvidious {
          ".kodi/userdata/addon_data/plugin.video.invidious/settings.xml" = {
            text = invidiousSettingsXml;
            force = true;
          };
        }
        // lib.optionalAttrs hasMediaSources {
          ".kodi/userdata/sources.xml" = {
            text = sourcesXml;
            force = true;
          };
        };

      home.activation.enableKodiAddons = lib.mkIf (enabledAddonIds != [ ]) (lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        db="${config.home.homeDirectory}/.kodi/userdata/Database/Addons33.db"
        if [ -f "$db" ] && [ "$(${pkgs.sqlite}/bin/sqlite3 "$db" "select count(*) from sqlite_master where type = 'table' and name = 'installed';")" = "1" ]; then
          for addon_id in ${lib.escapeShellArgs enabledAddonIds}; do
            if ! ${pkgs.sqlite}/bin/sqlite3 "$db" "insert into installed (addonID, enabled, installDate, disabledReason) values ('$addon_id', 1, datetime('now'), 0) on conflict(addonID) do update set enabled = 1, disabledReason = 0;"; then
              echo "warning: could not enable Kodi add-on $addon_id in $db; Kodi may be running" >&2
            fi
          done
        fi
      '');
    })
  ];
}
