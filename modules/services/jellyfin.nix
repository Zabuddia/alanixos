{ config, lib, pkgs, pkgs-unstable, ... }:
let
  cfg = config.alanix.jellyfin;
  tvheadendCfg = config.alanix.tvheadend;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  serviceIdentity = import ../../lib/mkServiceIdentity.nix { inherit lib; };
  passwordUsers = import ../../lib/mkPlaintextPasswordUsers.nix { inherit lib; };

  exposeCfg = cfg.expose;
  inherit (passwordUsers) hasValue;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;

  configDir = "${cfg.dataDir}/config";
  logDir = "${cfg.dataDir}/log";
  networkConfigPath = "${configDir}/network.xml";
  systemConfigPath = "${configDir}/system.xml";
  bootstrapMarkerPath = "${configDir}/.alanix-users-bootstrapped";
  externalPort = serviceIdentity.externalPort {
    inherit exposeCfg;
    port = cfg.port;
  };

  listenAddressIsIpv6 = hasValue cfg.listenAddress && lib.hasInfix ":" cfg.listenAddress;
  xmlBool = value: if value then "true" else "false";
  sanitizeUserKey = name: lib.replaceStrings [ "-" "." "@" "+" " " ] [ "_" "_" "_" "_" "_" ] name;
  collectionTypes = [
    "movies"
    "tvshows"
    "music"
    "musicvideos"
    "homevideos"
    "boxsets"
    "books"
    "mixed"
  ];

  adminUsers = lib.filterAttrs (_: userCfg: userCfg.admin) cfg.users;
  adminUserNames = builtins.attrNames adminUsers;
  bootstrapAdminName = if adminUserNames == [ ] then null else builtins.head adminUserNames;
  bootstrapPassVar = if bootstrapAdminName == null then "" else "PASSFILE_" + sanitizeUserKey bootstrapAdminName;

  effectiveLibraries =
    lib.mapAttrs
      (_: libraryCfg:
        let
          folderPaths =
            if libraryCfg.folder != null && lib.hasAttrByPath [ libraryCfg.folder ] cfg.mediaFolders then
              [ cfg.mediaFolders.${libraryCfg.folder}.path ]
            else
              [ ];
        in
        libraryCfg
        // {
          effectivePaths = lib.unique (folderPaths ++ libraryCfg.paths);
        })
      cfg.libraries;

  effectiveTvheadendBaseUrl =
    if hasValue cfg.liveTv.tvheadend.baseUrl then
      cfg.liveTv.tvheadend.baseUrl
    else if tvheadendCfg.enable then
      "http://${tvheadendCfg.listenAddress}:${toString tvheadendCfg.port}"
    else
      null;

  effectiveLiveTvRecordingPath =
    if cfg.liveTv.recordingPath != null then
      cfg.liveTv.recordingPath
    else if tvheadendCfg.enable && tvheadendCfg.recordingsDir != null then
      tvheadendCfg.recordingsDir
    else
      null;

  liveTvEnabled = cfg.liveTv.tvheadend.enable;
  liveTvPasswordSourceCount =
    builtins.length (
      lib.filter (x: x) [
        (cfg.liveTv.tvheadend.password != null)
        (cfg.liveTv.tvheadend.passwordFile != null)
        (cfg.liveTv.tvheadend.passwordSecret != null)
      ]
    );
  reconcileEnabled = cfg.users != { } || cfg.libraries != { } || liveTvEnabled;

  sanitizedUsersForRestart = passwordUsers.sanitizeForRestart {
    users = cfg.users;
    inheritFields = [ "admin" "passwordSecret" ];
  };

  sanitizedLibrariesForRestart =
    lib.mapAttrs
      (_: libraryCfg: {
        inherit (libraryCfg) type folder paths;
      })
      cfg.libraries;

  sanitizedLiveTvForRestart = {
    enable = liveTvEnabled;
    baseUrl = effectiveTvheadendBaseUrl;
    recordingPath = effectiveLiveTvRecordingPath;
    playlistPath = cfg.liveTv.tvheadend.playlistPath;
    xmltvPath = cfg.liveTv.tvheadend.xmltvPath;
    username = cfg.liveTv.tvheadend.username;
    passwordSecret = cfg.liveTv.tvheadend.passwordSecret;
    password =
      if cfg.liveTv.tvheadend.password == null then
        null
      else
        builtins.hashString "sha256" cfg.liveTv.tvheadend.password;
    passwordFile =
      if cfg.liveTv.tvheadend.passwordFile == null then
        null
      else
        toString cfg.liveTv.tvheadend.passwordFile;
  };

  mediaTmpfilesRules =
    lib.unique (
      lib.flatten (
        lib.mapAttrsToList
          (_: folderCfg:
            lib.optional folderCfg.create
              "d ${folderCfg.path} ${folderCfg.mode} ${folderCfg.user} ${folderCfg.group} - -")
          cfg.mediaFolders
      )
    );
in
{
  options.alanix.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin (Alanix)";

    package = lib.mkPackageOption pkgs-unstable "jellyfin" { };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Bind address written into Jellyfin's network.xml.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port written into Jellyfin's network.xml.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/jellyfin";
      description = "Jellyfin state directory.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/jellyfin";
      description = "Jellyfin cache directory.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra groups granted to the Jellyfin service user so it can read media files.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = passwordUsers.mkOptions {
          extraOptions = {
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this Jellyfin user should be an admin.";
            };
          };
        };
      }));
      default = { };
      description = "Declarative Jellyfin users keyed by username.";
    };

    mediaFolders = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            description = "Absolute filesystem path Jellyfin should be able to read.";
          };

          create = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to create the directory through systemd-tmpfiles.";
          };

          user = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Owner used when create = true.";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Group used when create = true.";
          };

          mode = lib.mkOption {
            type = lib.types.strMatching "^[0-7]{4}$";
            default = "0755";
            description = "Mode used when create = true.";
          };
        };
      }));
      default = { };
      description = "Filesystem directories made available to Jellyfin.";
    };

    libraries = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          type = lib.mkOption {
            type = lib.types.enum collectionTypes;
            description = "Jellyfin library type.";
          };

          folder = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional alanix.jellyfin.mediaFolders key included in this library.";
          };

          paths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Extra absolute paths included in this library.";
          };
        };
      }));
      default = { };
      description = "Declarative Jellyfin libraries keyed by their display name.";
    };

    liveTv = {
      recordingPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional Jellyfin Live TV recording directory.";
      };

      tvheadend = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Configure Jellyfin Live TV from TVHeadend using its M3U and XMLTV endpoints.";
        };

        baseUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional TVHeadend base URL. Defaults to alanix.tvheadend.listenAddress/port.";
        };

        playlistPath = lib.mkOption {
          type = lib.types.str;
          default = "/playlist/channels";
          description = "Path appended to baseUrl for the TVHeadend M3U playlist.";
        };

        xmltvPath = lib.mkOption {
          type = lib.types.str;
          default = "/xmltv/channels";
          description = "Path appended to baseUrl for the TVHeadend XMLTV guide.";
        };

        username = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional TVHeadend username if the playlist and XMLTV endpoints require auth.";
        };

        password = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Plaintext TVHeadend password (simple, not recommended).";
        };

        passwordFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to a file containing the plaintext TVHeadend password.";
        };

        passwordSecret = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Name of a sops secret containing the plaintext TVHeadend password.";
        };
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "jellyfin";
      serviceDescription = "Jellyfin";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.jellyfin.listenAddress must be set when alanix.jellyfin.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.jellyfin.port must be set when alanix.jellyfin.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.jellyfin.dataDir must be an absolute path.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.cacheDir;
            message = "alanix.jellyfin.cacheDir must be an absolute path.";
          }
          {
            assertion = cfg.users == { } || adminUserNames != [ ];
            message = "alanix.jellyfin: at least one declared user must have admin = true.";
          }
          {
            assertion = !(cfg.libraries != { } || liveTvEnabled) || cfg.users != { };
            message = "alanix.jellyfin: declarative libraries and Live TV require at least one declared admin user.";
          }
          {
            assertion = !liveTvEnabled || hasValue effectiveTvheadendBaseUrl;
            message = "alanix.jellyfin.liveTv.tvheadend.enable requires either alanix.jellyfin.liveTv.tvheadend.baseUrl or an enabled alanix.tvheadend service.";
          }
          {
            assertion = effectiveTvheadendBaseUrl == null || builtins.match "^https?://.+" effectiveTvheadendBaseUrl != null;
            message = "alanix.jellyfin.liveTv.tvheadend.baseUrl must start with http:// or https://.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.liveTv.tvheadend.playlistPath;
            message = "alanix.jellyfin.liveTv.tvheadend.playlistPath must start with /.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.liveTv.tvheadend.xmltvPath;
            message = "alanix.jellyfin.liveTv.tvheadend.xmltvPath must start with /.";
          }
          {
            assertion = effectiveLiveTvRecordingPath == null || lib.hasPrefix "/" effectiveLiveTvRecordingPath;
            message = "alanix.jellyfin.liveTv.recordingPath must be an absolute path.";
          }
          {
            assertion =
              if hasValue cfg.liveTv.tvheadend.username || liveTvPasswordSourceCount != 0 then
                hasValue cfg.liveTv.tvheadend.username && liveTvPasswordSourceCount == 1
              else
                true;
            message = "alanix.jellyfin.liveTv.tvheadend: set username plus exactly one of password, passwordFile, or passwordSecret when TVHeadend auth is required.";
          }
          {
            assertion =
              cfg.liveTv.tvheadend.passwordSecret == null
              || lib.hasAttrByPath [ "sops" "secrets" cfg.liveTv.tvheadend.passwordSecret ] config;
            message = "alanix.jellyfin.liveTv.tvheadend.passwordSecret must reference a declared sops secret.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.jellyfin.expose";
        }
        ++ passwordUsers.mkAssertions {
          inherit config;
          users = cfg.users;
          usernamePattern = "^[A-Za-z0-9._-]+$";
          usernameMessage = uname: "alanix.jellyfin.users.${uname}: usernames may contain only letters, digits, dot, underscore, and hyphen.";
          passwordSourceMessage = uname: "alanix.jellyfin.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          passwordSecretMessage = uname: "alanix.jellyfin.users.${uname}.passwordSecret must reference a declared sops secret.";
        }
        ++ lib.flatten (
          lib.mapAttrsToList
            (folderName: folderCfg: [
              {
                assertion = lib.hasPrefix "/" folderCfg.path;
                message = "alanix.jellyfin.mediaFolders.${folderName}.path must be an absolute path.";
              }
            ])
            cfg.mediaFolders
        )
        ++ lib.flatten (
          lib.mapAttrsToList
            (libraryName: libraryCfg: [
              {
                assertion = libraryCfg.folder == null || lib.hasAttrByPath [ libraryCfg.folder ] cfg.mediaFolders;
                message = "alanix.jellyfin.libraries.${libraryName}.folder must reference an existing alanix.jellyfin.mediaFolders entry.";
              }
              {
                assertion = lib.all (path: lib.hasPrefix "/" path) libraryCfg.paths;
                message = "alanix.jellyfin.libraries.${libraryName}.paths must contain only absolute paths.";
              }
              {
                assertion = builtins.length effectiveLibraries.${libraryName}.effectivePaths > 0;
                message = "alanix.jellyfin.libraries.${libraryName} must contain at least one path, either through folder or paths.";
              }
            ])
            cfg.libraries
        );

      services.jellyfin = lib.mkIf baseConfigReady {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;
        cacheDir = cfg.cacheDir;
        inherit configDir logDir;
        openFirewall = false;
      };

      users.users.${config.services.jellyfin.user}.extraGroups = cfg.extraGroups;

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady mediaTmpfilesRules;

      systemd.services."alanix-jellyfin-network-config" = lib.mkIf baseConfigReady {
        description = "Write Jellyfin network.xml";
        before = [ "jellyfin.service" ];
        requiredBy = [ "jellyfin.service" ];

        serviceConfig = {
          Type = "oneshot";
        };

        path = [ pkgs.coreutils pkgs.python3 ];

        script = ''
          install -d -m 0700 -o ${config.services.jellyfin.user} -g ${config.services.jellyfin.group} \
            ${lib.escapeShellArg cfg.dataDir} \
            ${lib.escapeShellArg configDir} \
            ${lib.escapeShellArg logDir} \
            ${lib.escapeShellArg cfg.cacheDir}

          cat > ${lib.escapeShellArg networkConfigPath} <<EOF
          <?xml version="1.0" encoding="utf-8"?>
          <NetworkConfiguration>
            <InternalHttpPort>${toString cfg.port}</InternalHttpPort>
            <PublicHttpPort>${toString externalPort}</PublicHttpPort>
            <EnableHttps>false</EnableHttps>
            <RequireHttps>false</RequireHttps>
            <EnableIPv4>${xmlBool (!listenAddressIsIpv6)}</EnableIPv4>
            <EnableIPv6>${xmlBool listenAddressIsIpv6}</EnableIPv6>
            <AutoDiscovery>false</AutoDiscovery>
            <EnableRemoteAccess>true</EnableRemoteAccess>
            <EnablePublishedServerUriByRequest>true</EnablePublishedServerUriByRequest>
            <LocalNetworkAddresses>
              <string>${cfg.listenAddress}</string>
            </LocalNetworkAddresses>
          </NetworkConfiguration>
          EOF

          chown ${config.services.jellyfin.user}:${config.services.jellyfin.group} ${lib.escapeShellArg networkConfigPath}
          chmod 0600 ${lib.escapeShellArg networkConfigPath}

          ${lib.optionalString (cfg.users != { }) ''
            python3 - <<'PY'
            from pathlib import Path
            import re

            path = Path(${builtins.toJSON systemConfigPath})
            marker = Path(${builtins.toJSON bootstrapMarkerPath})
            desired = "true" if marker.exists() else "false"
            if path.exists():
                text = path.read_text()
            else:
                text = '<?xml version="1.0" encoding="utf-8"?>\n<ServerConfiguration>\n</ServerConfiguration>\n'

            if "<IsStartupWizardCompleted>" in text:
                text = re.sub(
                    r"<IsStartupWizardCompleted>.*?</IsStartupWizardCompleted>",
                    f"<IsStartupWizardCompleted>{desired}</IsStartupWizardCompleted>",
                    text,
                    count=1,
                    flags=re.S,
                )
            elif "</ServerConfiguration>" in text:
                text = text.replace(
                    "</ServerConfiguration>",
                    f"  <IsStartupWizardCompleted>{desired}</IsStartupWizardCompleted>\n</ServerConfiguration>",
                    1,
                )
            else:
                text = f'<?xml version="1.0" encoding="utf-8"?>\n<ServerConfiguration>\n  <IsStartupWizardCompleted>{desired}</IsStartupWizardCompleted>\n</ServerConfiguration>\n'

            path.write_text(text)
            PY

            chown ${config.services.jellyfin.user}:${config.services.jellyfin.group} ${lib.escapeShellArg systemConfigPath}
            chmod 0600 ${lib.escapeShellArg systemConfigPath}
          ''}
        '';
      };

      systemd.services.jellyfin = lib.mkIf baseConfigReady {
        after = [ "alanix-jellyfin-network-config.service" ];
        requires = [ "alanix-jellyfin-network-config.service" ];
        serviceConfig.ExecStartPost = lib.optional reconcileEnabled
          "+${pkgs.writeShellScript "alanix-jellyfin-trigger-reconcile" ''
            ${config.systemd.package}/bin/systemctl --no-block start jellyfin-reconcile-users.service >/dev/null 2>&1 || true
          ''}";
      };

      systemd.services.jellyfin-reconcile-users = lib.mkIf (reconcileEnabled && baseConfigReady && cfg.users != { }) {
        description = "Reconcile Jellyfin users, libraries, and Live TV";
        after = [ "jellyfin.service" "sops-nix.service" ];
        wants = [ "sops-nix.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          RuntimeDirectory = "alanix-jellyfin";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };

        path = [
          pkgs.coreutils
          pkgs.curl
          pkgs.jq
        ];

        script =
          let
            usersFile =
              pkgs.writeText "alanix-jellyfin-users.json" (
                builtins.toJSON (
                  lib.mapAttrs (_: userCfg: {
                    admin = userCfg.admin;
                  }) cfg.users
                )
              );

            librariesFile =
              pkgs.writeText "alanix-jellyfin-libraries.json" (
                builtins.toJSON (
                  lib.mapAttrs (_: libraryCfg: {
                    inherit (libraryCfg) type;
                    paths = libraryCfg.effectivePaths;
                  }) effectiveLibraries
                )
              );

            liveTvFile =
              pkgs.writeText "alanix-jellyfin-livetv.json" (
                builtins.toJSON {
                  enabled = liveTvEnabled;
                  baseUrl = if effectiveTvheadendBaseUrl == null then "" else effectiveTvheadendBaseUrl;
                  recordingPath = effectiveLiveTvRecordingPath;
                  playlistPath = cfg.liveTv.tvheadend.playlistPath;
                  xmltvPath = cfg.liveTv.tvheadend.xmltvPath;
                  username = if cfg.liveTv.tvheadend.username == null then "" else cfg.liveTv.tvheadend.username;
                }
              );

            passfileLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: userCfg:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                    runtimePassfile = "$RUNTIME_DIRECTORY/${sanitizeUserKey uname}.pass";
                  in
                  if userCfg.passwordFile != null then
                    ''${var}=${lib.escapeShellArg (toString userCfg.passwordFile)}''
                  else if userCfg.passwordSecret != null then
                    ''${var}=${lib.escapeShellArg config.sops.secrets.${userCfg.passwordSecret}.path}''
                  else
                    ''${var}=${lib.escapeShellArg runtimePassfile}; ensure_runtime_passfile "${"$"}${var}" ${lib.escapeShellArg userCfg.password}''
                ) cfg.users);

            tvheadendPassfileLine =
              let
                runtimePassfile = "$RUNTIME_DIRECTORY/tvheadend.pass";
              in
              if cfg.liveTv.tvheadend.passwordFile != null then
                ''TVHEADEND_PASSFILE=${lib.escapeShellArg (toString cfg.liveTv.tvheadend.passwordFile)}''
              else if cfg.liveTv.tvheadend.passwordSecret != null then
                ''TVHEADEND_PASSFILE=${lib.escapeShellArg config.sops.secrets.${cfg.liveTv.tvheadend.passwordSecret}.path}''
              else if cfg.liveTv.tvheadend.password != null then
                ''TVHEADEND_PASSFILE=${lib.escapeShellArg runtimePassfile}; ensure_runtime_passfile "$TVHEADEND_PASSFILE" ${lib.escapeShellArg cfg.liveTv.tvheadend.password}''
              else
                ''TVHEADEND_PASSFILE=""'';

            passfileLookupLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: _:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                  in
                  ''
                    if [ "$username" = ${lib.escapeShellArg uname} ]; then
                      printf '%s\n' "${"$"}${var}"
                      return 0
                    fi
                  ''
                ) cfg.users);

            loginDeclaredAdminLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: userCfg:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                  in
                  lib.optionalString userCfg.admin ''
                    if token="$(authenticate_user ${lib.escapeShellArg uname} "${"$"}${var}")"; then
                      ACTING_TOKEN="$token"
                      ACTING_USER=${lib.escapeShellArg uname}
                      return 0
                    fi
                  ''
                ) cfg.users);
          in
          ''
            set -euo pipefail

            BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}
            AUTHORIZATION_HEADER='MediaBrowser Client="alanix-jellyfin-reconcile", Device="alanix-jellyfin-reconcile", DeviceId="alanix-jellyfin-reconcile", Version="1.0.0"'
            USERS_FILE=${lib.escapeShellArg usersFile}
            LIBRARIES_FILE=${lib.escapeShellArg librariesFile}
            LIVETV_FILE=${lib.escapeShellArg liveTvFile}
            BOOTSTRAP_ADMIN=${lib.escapeShellArg (if bootstrapAdminName == null then "" else bootstrapAdminName)}
            BOOTSTRAP_PASSVAR=${lib.escapeShellArg bootstrapPassVar}
            BOOTSTRAP_MARKER=${lib.escapeShellArg bootstrapMarkerPath}
            IMPLICIT_BOOTSTRAP_USER=${lib.escapeShellArg config.services.jellyfin.user}
            TVHEADEND_SOURCE_MARKER="alanix-tvheadend"
            TVHEADEND_LISTINGS_MARKER="alanix-tvheadend"
            ACTING_TOKEN=""
            ACTING_USER=""
            USED_IMPLICIT_BOOTSTRAP=0

            ensure_runtime_passfile() {
              local path="$1"
              local value="$2"
              umask 077
              printf '%s' "$value" > "$path"
            }

            ${passfileLines}
            ${tvheadendPassfileLine}

            passfile_for_username() {
              local username="$1"
              ${passfileLookupLines}

              return 1
            }

            uri_encode() {
              jq -rn --arg value "$1" '$value|@uri'
            }

            join_url() {
              local base_url="$1"
              local path="$2"
              printf '%s%s\n' "''${base_url%/}" "$path"
            }

            with_basic_auth_url() {
              local base_url="$1"
              local path="$2"
              local username="$3"
              local passfile="$4"
              local password
              local encoded_user
              local encoded_password

              if [ -z "$username" ] || [ -z "$passfile" ]; then
                join_url "$base_url" "$path"
                return 0
              fi

              password="$(tr -d '\r\n' < "$passfile")"
              encoded_user="$(uri_encode "$username")"
              encoded_password="$(uri_encode "$password")"

              case "$base_url" in
                http://*)
                  printf 'http://%s:%s@%s%s\n' "$encoded_user" "$encoded_password" "''${base_url#http://}" "$path"
                  ;;
                https://*)
                  printf 'https://%s:%s@%s%s\n' "$encoded_user" "$encoded_password" "''${base_url#https://}" "$path"
                  ;;
                *)
                  echo "TVHeadend baseUrl must start with http:// or https://." >&2
                  return 1
                  ;;
              esac
            }

            wait_for_server() {
              local attempts=120

              while [ "$attempts" -gt 0 ]; do
                if curl -sS -f "$BASE_URL/System/Ping" >/dev/null 2>&1; then
                  return 0
                fi

                sleep 1
                attempts=$((attempts - 1))
              done

              echo "Timed out waiting for Jellyfin to become ready." >&2
              return 1
            }

            public_post_json() {
              local path="$1"
              local body="$2"
              curl -sS -f \
                -H "Authorization: $AUTHORIZATION_HEADER" \
                -H 'Content-Type: application/json' \
                -X POST \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_get() {
              local path="$1"
              curl -sS -f \
                -H "Authorization: $AUTHORIZATION_HEADER" \
                -H "X-Emby-Token: $ACTING_TOKEN" \
                "$BASE_URL$path"
            }

            api_post_json() {
              local path="$1"
              local body="$2"
              curl -sS -f \
                -H "Authorization: $AUTHORIZATION_HEADER" \
                -H "X-Emby-Token: $ACTING_TOKEN" \
                -H 'Content-Type: application/json' \
                -X POST \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_delete() {
              local path="$1"
              curl -sS -f \
                -H "Authorization: $AUTHORIZATION_HEADER" \
                -H "X-Emby-Token: $ACTING_TOKEN" \
                -X DELETE \
                "$BASE_URL$path"
            }

            startup_is_incomplete() {
              local code
              code="$(
                curl -sS -o /dev/null -w '%{http_code}' \
                  -H "Authorization: $AUTHORIZATION_HEADER" \
                  "$BASE_URL/Startup/User" \
                  || true
              )"

              [ "$code" = "200" ]
            }

            wait_for_startup_user() {
              local attempts=30
              local code

              while [ "$attempts" -gt 0 ]; do
                code="$(
                  curl -sS -o "$RUNTIME_DIRECTORY/startup-user.json" -w '%{http_code}' \
                    -H "Authorization: $AUTHORIZATION_HEADER" \
                    "$BASE_URL/Startup/User" \
                    || true
                )"

                if [ "$code" = "200" ]; then
                  return 0
                fi

                sleep 1
                attempts=$((attempts - 1))
              done

              return 1
            }

            authenticate_user_inline() {
              local username="$1"
              local password="$2"
              local payload
              local response

              payload="$(jq -n --arg username "$username" --arg password "$password" '{ Username: $username, Pw: $password }')"
              response="$(public_post_json "/Users/AuthenticateByName" "$payload" 2>/dev/null)" || return 1
              printf '%s' "$response" | jq -er '.AccessToken'
            }

            authenticate_user() {
              local username="$1"
              local passfile="$2"
              local password

              password="$(tr -d '\r\n' < "$passfile")"
              authenticate_user_inline "$username" "$password"
            }

            bootstrap_first_admin() {
              local password
              local payload

              if [ -z "$BOOTSTRAP_ADMIN" ] || [ -z "$BOOTSTRAP_PASSVAR" ]; then
                echo "No declared admin is available to bootstrap Jellyfin." >&2
                return 1
              fi

              if ! wait_for_startup_user; then
                echo "Jellyfin startup user endpoint never became ready for bootstrap." >&2
                return 1
              fi

              password="$(tr -d '\r\n' < "''${!BOOTSTRAP_PASSVAR}")"
              payload="$(jq -n --arg name "$BOOTSTRAP_ADMIN" --arg password "$password" '{ Name: $name, Password: $password }')"

              echo "Bootstrapping first Jellyfin admin: $BOOTSTRAP_ADMIN"
              public_post_json "/Startup/User" "$payload" >/dev/null
              curl -sS -f \
                -H "Authorization: $AUTHORIZATION_HEADER" \
                -X POST \
                "$BASE_URL/Startup/Complete" >/dev/null
            }

            try_declared_admin_logins() {
              local token

              ${loginDeclaredAdminLines}

              return 1
            }

            try_implicit_bootstrap_login() {
              local token
              local username

              for username in "$IMPLICIT_BOOTSTRAP_USER" "MyJellyfinUser"; do
                if [ -z "$username" ]; then
                  continue
                fi

                if token="$(authenticate_user_inline "$username" "")"; then
                  ACTING_TOKEN="$token"
                  ACTING_USER="$username"
                  USED_IMPLICIT_BOOTSTRAP=1
                  return 0
                fi
              done

              return 1
            }

            fetch_users_json() {
              api_get "/Users"
            }

            fetch_libraries_json() {
              api_get "/Library/VirtualFolders"
            }

            fetch_livetv_json() {
              api_get "/System/Configuration/livetv"
            }

            user_id_for_name() {
              local users_json="$1"
              local username="$2"

              printf '%s' "$users_json" | jq -r --arg username "$username" '.[] | select(.Name == $username) | .Id' | head -n1
            }

            user_json_for_name() {
              local users_json="$1"
              local username="$2"

              printf '%s' "$users_json" | jq -c --arg username "$username" '.[] | select(.Name == $username)' | head -n1
            }

            library_json_for_name() {
              local libraries_json="$1"
              local library_name="$2"

              printf '%s' "$libraries_json" | jq -c --arg name "$library_name" '.[] | select(.Name == $name)' | head -n1
            }

            delete_user_by_name() {
              local username="$1"
              local user_id

              user_id="$(user_id_for_name "$USERS_JSON" "$username")"
              if [ -z "$user_id" ]; then
                return 0
              fi

              echo "Removing implicit Jellyfin bootstrap user: $username"
              api_delete "/Users/$user_id" >/dev/null
              USERS_JSON="$(fetch_users_json)"
            }

            ensure_user() {
              local username="$1"
              local passfile="$2"
              local want_admin="$3"

              local password
              local payload
              local user_id
              local user_json
              local admin_json
              local policy_json

              password="$(tr -d '\r\n' < "$passfile")"
              user_id="$(user_id_for_name "$USERS_JSON" "$username")"

              if [ -z "$user_id" ]; then
                echo "Creating Jellyfin user: $username"
                payload="$(jq -n --arg name "$username" --arg password "$password" '{ Name: $name, Password: $password }')"
                api_post_json "/Users/New" "$payload" >/dev/null
                USERS_JSON="$(fetch_users_json)"
                user_id="$(user_id_for_name "$USERS_JSON" "$username")"
              else
                payload="$(jq -n --arg currentPw "$password" --arg newPw "$password" '{ CurrentPw: $currentPw, NewPw: $newPw, ResetPassword: false }')"
                api_post_json "/Users/Password?userId=$user_id" "$payload" >/dev/null
              fi

              user_json="$(user_json_for_name "$USERS_JSON" "$username")"
              if [ -z "$user_json" ]; then
                echo "Could not read Jellyfin user after ensuring: $username" >&2
                return 1
              fi

              if [ "$want_admin" = "1" ]; then
                admin_json=true
              else
                admin_json=false
              fi

              policy_json="$(
                printf '%s' "$user_json" | jq -c --argjson admin "$admin_json" '.Policy + { IsAdministrator: $admin }'
              )"
              api_post_json "/Users/$user_id/Policy" "$policy_json" >/dev/null
              USERS_JSON="$(fetch_users_json)"
            }

            ensure_library() {
              local library_name="$1"
              local collection_type="$2"
              local desired_paths_json="$3"
              local existing_library_json
              local existing_type
              local existing_paths_json
              local payload
              local path

              existing_library_json="$(library_json_for_name "$LIBRARIES_JSON" "$library_name")"
              payload="$(
                jq -cn \
                  --argjson paths "$desired_paths_json" \
                  '{ LibraryOptions: { Enabled: true, PathInfos: ($paths | map({ Path: . })) } }'
              )"

              if [ -z "$existing_library_json" ]; then
                echo "Creating Jellyfin library: $library_name"
                api_post_json \
                  "/Library/VirtualFolders?name=$(uri_encode "$library_name")&collectionType=$(uri_encode "$collection_type")&refreshLibrary=true" \
                  "$payload" >/dev/null
                LIBRARIES_JSON="$(fetch_libraries_json)"
                return 0
              fi

              existing_type="$(printf '%s' "$existing_library_json" | jq -r '.CollectionType // ""')"
              existing_paths_json="$(printf '%s' "$existing_library_json" | jq -c '(.Locations // []) | sort')"

              if [ "$existing_type" != "$collection_type" ]; then
                echo "Recreating Jellyfin library with new type: $library_name"
                api_delete "/Library/VirtualFolders?name=$(uri_encode "$library_name")&refreshLibrary=true" >/dev/null
                api_post_json \
                  "/Library/VirtualFolders?name=$(uri_encode "$library_name")&collectionType=$(uri_encode "$collection_type")&refreshLibrary=true" \
                  "$payload" >/dev/null
                LIBRARIES_JSON="$(fetch_libraries_json)"
                return 0
              fi

              while IFS= read -r path; do
                [ -n "$path" ] || continue
                if ! jq -e --arg path "$path" 'index($path)' <<<"$desired_paths_json" >/dev/null; then
                  echo "Removing Jellyfin library path: $library_name -> $path"
                  api_delete "/Library/VirtualFolders/Paths?name=$(uri_encode "$library_name")&path=$(uri_encode "$path")&refreshLibrary=true" >/dev/null
                fi
              done < <(jq -r '.[]' <<<"$existing_paths_json")

              while IFS= read -r path; do
                [ -n "$path" ] || continue
                if ! jq -e --arg path "$path" 'index($path)' <<<"$existing_paths_json" >/dev/null; then
                  echo "Adding Jellyfin library path: $library_name -> $path"
                  api_post_json \
                    "/Library/VirtualFolders/Paths?refreshLibrary=true" \
                    "$(jq -cn --arg name "$library_name" --arg path "$path" '{ Name: $name, Path: $path }')" >/dev/null
                fi
              done < <(jq -r '.[]' <<<"$desired_paths_json")

              LIBRARIES_JSON="$(fetch_libraries_json)"
            }

            remove_managed_tvheadend_livetv() {
              local tuner_ids
              local listing_ids
              local id

              tuner_ids="$(printf '%s' "$LIVETV_JSON" | jq -r --arg source "$TVHEADEND_SOURCE_MARKER" '.TunerHosts[]? | select(.Source == $source) | .Id')"
              while IFS= read -r id; do
                [ -n "$id" ] || continue
                echo "Removing managed Jellyfin Live TV tuner: $id"
                api_delete "/LiveTv/TunerHosts?id=$(uri_encode "$id")" >/dev/null
              done <<<"$tuner_ids"

              listing_ids="$(printf '%s' "$LIVETV_JSON" | jq -r --arg listingsId "$TVHEADEND_LISTINGS_MARKER" '.ListingProviders[]? | select(.Type == "xmltv" and .ListingsId == $listingsId) | .Id')"
              while IFS= read -r id; do
                [ -n "$id" ] || continue
                echo "Removing managed Jellyfin Live TV guide provider: $id"
                api_delete "/LiveTv/ListingProviders?id=$(uri_encode "$id")" >/dev/null
              done <<<"$listing_ids"

              LIVETV_JSON="$(fetch_livetv_json)"
            }

            sync_livetv_recording_paths() {
              local recording_path="$1"
              local updated_json

              if [ -z "$recording_path" ]; then
                return 0
              fi

              updated_json="$(
                printf '%s' "$LIVETV_JSON" | jq --arg recordingPath "$recording_path" '
                  .RecordingPath = $recordingPath
                  | .MovieRecordingPath = $recordingPath
                  | .SeriesRecordingPath = $recordingPath
                '
              )"

              if [ "$updated_json" != "$LIVETV_JSON" ]; then
                echo "Updating Jellyfin Live TV recording paths"
                api_post_json "/System/Configuration/livetv" "$updated_json" >/dev/null
                LIVETV_JSON="$updated_json"
              fi
            }

            ensure_tvheadend_livetv() {
              local enabled
              local base_url
              local recording_path
              local playlist_path
              local xmltv_path
              local username
              local playlist_url
              local xmltv_url
              local tuner_id
              local listing_id
              local tuner_payload
              local listing_payload

              LIVETV_JSON="$(fetch_livetv_json)"
              enabled="$(jq -r '.enabled' "$LIVETV_FILE")"

              if [ "$enabled" != "true" ]; then
                remove_managed_tvheadend_livetv
                return 0
              fi

              base_url="$(jq -r '.baseUrl' "$LIVETV_FILE")"
              recording_path="$(jq -r '.recordingPath // ""' "$LIVETV_FILE")"
              playlist_path="$(jq -r '.playlistPath' "$LIVETV_FILE")"
              xmltv_path="$(jq -r '.xmltvPath' "$LIVETV_FILE")"
              username="$(jq -r '.username // ""' "$LIVETV_FILE")"

              playlist_url="$(with_basic_auth_url "$base_url" "$playlist_path" "$username" "$TVHEADEND_PASSFILE")"
              xmltv_url="$(with_basic_auth_url "$base_url" "$xmltv_path" "$username" "$TVHEADEND_PASSFILE")"

              tuner_id="$(printf '%s' "$LIVETV_JSON" | jq -r --arg source "$TVHEADEND_SOURCE_MARKER" '.TunerHosts[]? | select(.Source == $source) | .Id' | head -n1)"
              listing_id="$(printf '%s' "$LIVETV_JSON" | jq -r --arg listingsId "$TVHEADEND_LISTINGS_MARKER" '.ListingProviders[]? | select(.Type == "xmltv" and .ListingsId == $listingsId) | .Id' | head -n1)"

              tuner_payload="$(
                jq -cn \
                  --arg id "$tuner_id" \
                  --arg type "m3u" \
                  --arg url "$playlist_url" \
                  --arg friendlyName "TVHeadend" \
                  --arg source "$TVHEADEND_SOURCE_MARKER" '
                    {
                      Type: $type,
                      Url: $url,
                      FriendlyName: $friendlyName,
                      Source: $source,
                      TunerCount: 0,
                      AllowStreamSharing: true,
                      AllowHWTranscoding: true,
                      IgnoreDts: true,
                      ReadAtNativeFramerate: false,
                      AllowFmp4TranscodingContainer: false,
                      FallbackMaxStreamingBitrate: 30000000
                    }
                    + (if $id == "" then {} else { Id: $id } end)
                  '
              )"

              listing_payload="$(
                jq -cn \
                  --arg id "$listing_id" \
                  --arg type "xmltv" \
                  --arg path "$xmltv_url" \
                  --arg listingsId "$TVHEADEND_LISTINGS_MARKER" '
                    {
                      Type: $type,
                      Path: $path,
                      ListingsId: $listingsId,
                      EnableAllTuners: true,
                      ChannelMappings: []
                    }
                    + (if $id == "" then {} else { Id: $id } end)
                  '
              )"

              echo "Reconciling Jellyfin Live TV from TVHeadend"
              api_post_json "/LiveTv/TunerHosts" "$tuner_payload" >/dev/null
              api_post_json "/LiveTv/ListingProviders" "$listing_payload" >/dev/null

              LIVETV_JSON="$(fetch_livetv_json)"
              sync_livetv_recording_paths "$recording_path"
            }

            wait_for_server

            if ! try_declared_admin_logins; then
              if [ ! -e "$BOOTSTRAP_MARKER" ]; then
                bootstrap_first_admin || true
              fi

              if ! try_declared_admin_logins; then
                if ! try_implicit_bootstrap_login; then
                  echo "Could not authenticate any declared Jellyfin admin." >&2
                  exit 1
                fi
              fi
            fi

            USERS_JSON="$(fetch_users_json)"
            LIBRARIES_JSON="$(fetch_libraries_json)"

            while IFS=$'\t' read -r username admin_flag; do
              passfile="$(passfile_for_username "$username")" || {
                echo "Missing password source for Jellyfin user: $username" >&2
                exit 1
              }
              ensure_user "$username" "$passfile" "$admin_flag"
            done < <(
              jq -r 'to_entries[] | [.key, (if .value.admin then "1" else "0" end)] | @tsv' "$USERS_FILE"
            )

            while IFS=$'\t' read -r library_name collection_type desired_paths_json; do
              ensure_library "$library_name" "$collection_type" "$desired_paths_json"
            done < <(
              jq -r 'to_entries[] | [.key, .value.type, (.value.paths | sort | tojson)] | @tsv' "$LIBRARIES_FILE"
            )

            if ! ensure_tvheadend_livetv; then
              echo "Warning: could not reconcile Jellyfin Live TV from TVHeadend." >&2
            fi

            touch "$BOOTSTRAP_MARKER"
            chown ${config.services.jellyfin.user}:${config.services.jellyfin.group} "$BOOTSTRAP_MARKER"
            chmod 0600 "$BOOTSTRAP_MARKER"

            if [ "$USED_IMPLICIT_BOOTSTRAP" = "1" ] && ! jq -e --arg username "$ACTING_USER" 'has($username)' "$USERS_FILE" >/dev/null; then
              delete_user_by_name "$ACTING_USER"
            fi
          '';

        restartTriggers = [
          (builtins.toJSON sanitizedUsersForRestart)
          (builtins.toJSON sanitizedLibrariesForRestart)
          (builtins.toJSON sanitizedLiveTvForRestart)
        ];
      };
    }

    (lib.mkIf baseConfigReady (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "jellyfin";
        serviceDescription = "Jellyfin";
      }
    ))
  ]);
}
