{ config, lib, pkgs, ... }:

let
  inherit (lib) types;

  cfg = config.kodi;

  hasTvheadend = cfg.tvheadend.servers != [ ];
  hasHdhomerun = cfg.hdhomerun.enable;
  hasInvidious = cfg.invidious.enable;
  hasInvidiousUrl = hasInvidious && cfg.invidious.instanceUrl != null;
  hasInvidiousUsername = hasInvidious && cfg.invidious.username != null;
  hasInvidiousAuth = hasInvidious && cfg.invidious.passwordFile != null;
  invidiousInstanceUrl = if cfg.invidious.instanceUrl != null then cfg.invidious.instanceUrl else "";
  invidiousUsername = lib.escapeXML (lib.optionalString (cfg.invidious.username != null) cfg.invidious.username);
  hasInputstreamAdaptive = cfg.inputstreamAdaptive.enable;
  hasJellyfin = cfg.jellyfin.enable;

  kodiPackage = cfg.package.withPackages (p:
    [ p.joystick ]
    ++ lib.optionals hasTvheadend [ p.pvr-hts ]
    ++ lib.optionals hasHdhomerun [ p.pvr-hdhomerun ]
    ++ lib.optionals hasInvidious [ p.invidious ]
    ++ lib.optionals hasJellyfin [ p.jellyfin ]
    ++ lib.optionals hasInputstreamAdaptive [ p.inputstream-adaptive ]);

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

  hdhomerunSettingsXml = ''
    <settings version="2">
        <setting id="hide_protected">${lib.boolToString cfg.hdhomerun.hideProtected}</setting>
        <setting id="debug">${lib.boolToString cfg.hdhomerun.debug}</setting>
        <setting id="hide_duplicate">${lib.boolToString cfg.hdhomerun.hideDuplicate}</setting>
        <setting id="mark_new">${lib.boolToString cfg.hdhomerun.markNew}</setting>
        <setting id="http_discovery">${lib.boolToString cfg.hdhomerun.httpDiscovery}</setting>
    </settings>
  '';

  invidiousSettingsXml = ''
    <settings version="2">
        <setting id="auto_instance">false</setting>
    ${lib.optionalString hasInvidiousUrl ''
        <setting id="instance_url">${lib.escapeXML invidiousInstanceUrl}</setting>
    ''}
        <setting id="disable_dash">${lib.boolToString cfg.invidious.disableDash}</setting>
    ${lib.optionalString hasInvidiousUsername ''
        <setting id="instance_username">${invidiousUsername}</setting>
        <setting id="mark_items_watched">${lib.boolToString cfg.invidious.markItemsWatched}</setting>
    ''}
    </settings>
  '';

  inputstreamAdaptiveSettingsXml = ''
    <settings version="2">
        <setting id="adaptivestream.type">${lib.escapeXML cfg.inputstreamAdaptive.streamSelectionType}</setting>
        <setting id="adaptivestream.res.max">${lib.escapeXML cfg.inputstreamAdaptive.maxResolution}</setting>
        <setting id="adaptivestream.res.secure.max">${lib.escapeXML cfg.inputstreamAdaptive.secureMaxResolution}</setting>
        <setting id="adaptivestream.bandwidth.init.auto">${lib.boolToString cfg.inputstreamAdaptive.autoInitialBandwidth}</setting>
        <setting id="adaptivestream.bandwidth.init">${toString cfg.inputstreamAdaptive.initialBandwidthKbps}</setting>
        <setting id="adaptivestream.bandwidth.min">${toString cfg.inputstreamAdaptive.minBandwidthKbps}</setting>
        <setting id="adaptivestream.bandwidth.max">${toString cfg.inputstreamAdaptive.maxBandwidthKbps}</setting>
        <setting id="overrides.ignore.screen.res.change">${lib.boolToString cfg.inputstreamAdaptive.ignoreScreenResolutionChanges}</setting>
        <setting id="overrides.ignore.screen.res">${lib.boolToString cfg.inputstreamAdaptive.ignoreScreenResolution}</setting>
    </settings>
  '';

  hasMediaSources = cfg.mediaSources.video != [ ] || cfg.mediaSources.music != [ ];
  enabledAddonIds =
    lib.optionals hasTvheadend [ "pvr.hts" ]
    ++ lib.optionals hasHdhomerun [ "pvr.hdhomerun" ]
    ++ lib.optionals hasInvidious [ "plugin.video.invidious" ]
    ++ lib.optionals hasJellyfin [ "plugin.video.jellyfin" ]
    ++ lib.optionals hasInputstreamAdaptive [ "inputstream.adaptive" ];

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

    hdhomerun = {
      enable = lib.mkEnableOption "HDHomeRun Kodi PVR add-on";

      hideProtected = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether the Kodi HDHomeRun PVR add-on should hide protected channels.";
      };

      hideDuplicate = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether the Kodi HDHomeRun PVR add-on should hide duplicate channels.";
      };

      markNew = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether the Kodi HDHomeRun PVR add-on should mark new shows.";
      };

      httpDiscovery = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether the Kodi HDHomeRun PVR add-on should try SiliconDust HTTP discovery before LAN broadcast discovery.";
      };

      debug = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether the Kodi HDHomeRun PVR add-on should enable debug logging.";
      };
    };

    invidious = {
      enable = lib.mkEnableOption "Invidious Kodi add-on";

      instanceUrl = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Invidious instance URL used by the Kodi add-on.";
      };

      disableDash = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether the Kodi Invidious add-on should avoid DASH playback and use progressive streams.";
      };

      username = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Invidious account username. When set, the add-on will show Feed and Subscriptions.";
      };

      passwordFile = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to a file containing the Invidious account password. Read at activation time; never stored in the Nix store.";
      };

      markItemsWatched = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether the Kodi Invidious add-on should mark items as watched on the Invidious instance.";
      };
    };

    jellyfin = {
      enable = lib.mkEnableOption "Jellyfin Kodi add-on";
    };

    inputstreamAdaptive = {
      enable = lib.mkEnableOption "Kodi InputStream Adaptive settings";

      streamSelectionType = lib.mkOption {
        type = types.enum [ "default" "fixed-res" "ask-quality" "manual-osd" "test" ];
        default = "default";
        description = "Stream selection mode used by inputstream.adaptive.";
      };

      maxResolution = lib.mkOption {
        type = types.enum [ "auto" "480p" "640p" "720p" "1080p" "2K" "1440p" "4K" ];
        default = "auto";
        description = "Maximum video resolution inputstream.adaptive should choose.";
      };

      secureMaxResolution = lib.mkOption {
        type = types.enum [ "auto" "480p" "640p" "720p" "1080p" "2K" "1440p" "4K" ];
        default = "auto";
        description = "Maximum secure-stream video resolution inputstream.adaptive should choose.";
      };

      autoInitialBandwidth = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether inputstream.adaptive should estimate its initial bandwidth automatically.";
      };

      initialBandwidthKbps = lib.mkOption {
        type = types.int;
        default = 4000;
        description = "Initial bandwidth estimate in Kbps for inputstream.adaptive.";
      };

      minBandwidthKbps = lib.mkOption {
        type = types.int;
        default = 0;
        description = "Minimum stream bandwidth in Kbps for inputstream.adaptive; 0 leaves it unset.";
      };

      maxBandwidthKbps = lib.mkOption {
        type = types.int;
        default = 0;
        description = "Maximum stream bandwidth in Kbps for inputstream.adaptive; 0 leaves it unset.";
      };

      ignoreScreenResolution = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether inputstream.adaptive should ignore Kodi's current screen resolution when choosing quality.";
      };

      ignoreScreenResolutionChanges = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether inputstream.adaptive should ignore screen resolution changes while playing.";
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

  config._assertions = lib.optionals cfg.enable [
    {
      assertion = !(hasInvidiousAuth && cfg.invidious.instanceUrl == null);
      message = "kodi.invidious.instanceUrl must be set when kodi.invidious.passwordFile is set";
    }
    {
      assertion = !(hasInvidiousAuth && cfg.invidious.username == null);
      message = "kodi.invidious.username must be set when kodi.invidious.passwordFile is set";
    }
  ];

  config.home.modules = lib.optionals cfg.enable [
    ({ config, lib, ... }: {
      home.packages = [ kodiPackage ];
      home.file =
        lib.optionalAttrs hasTvheadend tvheadendFiles
        // lib.optionalAttrs hasHdhomerun {
          ".kodi/userdata/addon_data/pvr.hdhomerun/settings.xml" = {
            text = hdhomerunSettingsXml;
            force = true;
          };
        }
        // lib.optionalAttrs (hasInvidious && !hasInvidiousAuth) {
          ".kodi/userdata/addon_data/plugin.video.invidious/settings.xml" = {
            text = invidiousSettingsXml;
            force = true;
          };
        }
        // lib.optionalAttrs hasInputstreamAdaptive {
          ".kodi/userdata/addon_data/inputstream.adaptive/settings.xml" = {
            text = inputstreamAdaptiveSettingsXml;
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

      home.activation.writeInvidiousSettings = lib.mkIf hasInvidiousAuth (lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        settingsFile="${config.home.homeDirectory}/.kodi/userdata/addon_data/plugin.video.invidious/settings.xml"
        mkdir -p "$(dirname "$settingsFile")"
        rm -f "$settingsFile"
        password=$(< "${cfg.invidious.passwordFile}")
        escaped_password=$(printf '%s\n' "$password" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        {
          printf '%s\n' '<settings version="2">'
          printf '%s\n' '    <setting id="auto_instance">false</setting>'
          ${lib.optionalString hasInvidiousUrl ''printf '    <setting id="instance_url">%s</setting>\n' "${lib.escapeXML invidiousInstanceUrl}"''}
          printf '%s\n' '    <setting id="disable_dash">${lib.boolToString cfg.invidious.disableDash}</setting>'
          printf '%s\n' '    <setting id="instance_username">${invidiousUsername}</setting>'
          printf '    <setting id="instance_password">%s</setting>\n' "$escaped_password"
          printf '%s\n' '    <setting id="mark_items_watched">${lib.boolToString cfg.invidious.markItemsWatched}</setting>'
          printf '%s\n' '</settings>'
        } > "$settingsFile"
        chmod 600 "$settingsFile"
      '');
    })
  ];
}
