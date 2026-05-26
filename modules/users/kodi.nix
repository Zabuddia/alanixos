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

  hasMediaSources = cfg.mediaSources.video != [ ] || cfg.mediaSources.music != [ ];
  videoLibrarySources = lib.filter (source: source.content != null) cfg.mediaSources.video;
  hasVideoLibrarySources = videoLibrarySources != [ ];

  withTrailingSlash = path:
    if lib.hasSuffix "/" path then path else "${path}/";

  defaultVideoScraper = content: {
    movies = "metadata.themoviedb.org.python";
    tvshows = "metadata.tvshows.themoviedb.org.python";
  }.${content};

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

  mediaSourceOptions = {
    name = lib.mkOption {
      type = types.str;
      description = "Display name shown in Kodi.";
    };

    path = lib.mkOption {
      type = types.str;
      description = "Filesystem path Kodi should use for this media source.";
    };
  };

  videoSourceType = types.submodule {
    options = {
      content = lib.mkOption {
        type = types.nullOr (types.enum [ "movies" "tvshows" ]);
        default = null;
        description = "Kodi video library content type for this source. When unset, the source is available under Videos > Files only.";
      };

      scraper = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Kodi metadata scraper add-on ID for this source. Defaults to the standard Kodi scraper for the selected content type.";
      };

      scanRecursive = lib.mkOption {
        type = types.int;
        default = 0;
        description = "Kodi recursive scan setting stored for this video source.";
      };

      useFolderNames = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether Kodi should use folder names when scraping this video source.";
      };
    } // mediaSourceOptions;
  };

  musicSourceType = types.submodule {
    options = mediaSourceOptions;
  };

  sqlEscape = value: lib.replaceStrings [ "'" ] [ "''" ] value;
  sqlQuote = value: "'${sqlEscape value}'";

  videoSourcesSql = lib.concatMapStringsSep "\n"
    (source:
      let
        path = withTrailingSlash source.path;
        scraper = if source.scraper != null then source.scraper else defaultVideoScraper source.content;
      in
      ''
        INSERT INTO path (strPath, strContent, strScraper, scanRecursive, useFolderNames, noUpdate, exclude)
        SELECT ${sqlQuote path}, ${sqlQuote source.content}, ${sqlQuote scraper}, ${toString source.scanRecursive}, ${if source.useFolderNames then "1" else "0"}, 0, 0
        WHERE NOT EXISTS (SELECT 1 FROM path WHERE strPath = ${sqlQuote path});

        UPDATE path
        SET strContent = ${sqlQuote source.content},
            strScraper = ${sqlQuote scraper},
            scanRecursive = ${toString source.scanRecursive},
            useFolderNames = ${if source.useFolderNames then "1" else "0"},
            noUpdate = 0,
            exclude = 0
        WHERE strPath = ${sqlQuote path};
      '')
    videoLibrarySources;

  startupVideoScanScript =
    lib.concatMapStringsSep "\n"
      (source: "xbmc.executebuiltin(${builtins.toJSON "UpdateLibrary(video,${withTrailingSlash source.path})"})")
      videoLibrarySources;

  startupMusicScanScript =
    lib.concatMapStringsSep "\n"
      (source: "xbmc.executebuiltin(${builtins.toJSON "UpdateLibrary(music,${withTrailingSlash source.path})"})")
      cfg.mediaSources.music;

  autoexecPy = ''
    import xbmc

    ${startupVideoScanScript}
    ${startupMusicScanScript}
  '';

  mediaSourcesActivationScript = ''
    db="$(ls -1 "$HOME/.kodi/userdata/Database"/MyVideos*.db 2>/dev/null | sort -V | tail -n 1 || true)"

    if [ -n "$db" ] && [ "$(${pkgs.sqlite}/bin/sqlite3 "$db" "select count(*) from sqlite_master where type = 'table' and name = 'path';")" = "1" ]; then
      if ! ${pkgs.sqlite}/bin/sqlite3 "$db" <<'SQL'
        PRAGMA busy_timeout = 5000;
        ${videoSourcesSql}
    SQL
      then
        echo "warning: could not configure Kodi video library sources in $db; Kodi may be running" >&2
      fi
    fi
  '';
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

    mediaSources = {
      video = lib.mkOption {
        type = types.listOf videoSourceType;
        default = [ ];
        description = "Video file sources declared in Kodi sources.xml.";
      };

      music = lib.mkOption {
        type = types.listOf musicSourceType;
        default = [ ];
        description = "Music file sources declared in Kodi sources.xml.";
      };

      updateLibraryOnStartup = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether Kodi should scan declared library sources each time it starts.";
      };
    };
  };

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ kodiPackage ];
      home.file =
        lib.optionalAttrs hasTvheadend tvheadendFiles
        // lib.optionalAttrs hasMediaSources {
          ".kodi/userdata/sources.xml" = {
            text = sourcesXml;
            force = true;
          };
        }
        // lib.optionalAttrs (cfg.mediaSources.updateLibraryOnStartup && (hasVideoLibrarySources || cfg.mediaSources.music != [ ])) {
          ".kodi/userdata/autoexec.py" = {
            text = autoexecPy;
            force = true;
          };
        };

      home.activation.enableKodiTvheadendPvr = lib.mkIf hasTvheadend (lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        db="${config.home.homeDirectory}/.kodi/userdata/Database/Addons33.db"
        if [ -f "$db" ] && [ "$(${pkgs.sqlite}/bin/sqlite3 "$db" "select count(*) from sqlite_master where type = 'table' and name = 'installed';")" = "1" ]; then
          if ! ${pkgs.sqlite}/bin/sqlite3 "$db" "update installed set enabled = 1, disabledReason = 0 where addonID = 'pvr.hts';"; then
            echo "warning: could not enable Kodi pvr.hts in $db; Kodi may be running" >&2
          fi
        fi
      '');

      home.activation.configureKodiVideoLibrarySources = lib.mkIf hasVideoLibrarySources (lib.hm.dag.entryAfter [ "linkGeneration" ] mediaSourcesActivationScript);
    })
  ];
}
