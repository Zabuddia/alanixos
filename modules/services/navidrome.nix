{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.navidrome;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;

  hasValue = value: value != null && value != "";
  sanitizeUserKey = name: lib.replaceStrings [ "-" "." "@" "+" " " ] [ "_" "_" "_" "_" "_" ] name;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady =
    hasValue cfg.listenAddress
    && cfg.port != null
    && cfg.mediaFolders ? music;

  adminUsers = lib.filterAttrs (_: userCfg: userCfg.admin) cfg.users;
  adminUserNames = builtins.attrNames adminUsers;
  bootstrapAdminName = if adminUserNames == [ ] then null else builtins.head adminUserNames;
  reconcileEnabled = cfg.users != { };

  sanitizedUsersForRestart =
    lib.mapAttrs (_: userCfg: { inherit (userCfg) admin passwordSecret; }) cfg.users;

  radioReconcileEnabled = cfg.internetRadioStations != { };
  sanitizedRadiosForRestart =
    lib.mapAttrs (_: radioCfg: { inherit (radioCfg) name streamUrl homePageUrl; }) cfg.internetRadioStations;

  adminPassfilePath =
    if bootstrapAdminName != null
    then config.sops.secrets.${adminUsers.${bootstrapAdminName}.passwordSecret}.path
    else "";

  passfileLines =
    lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (uname: userCfg:
          let var = "PASSFILE_" + sanitizeUserKey uname;
          in ''${var}=${lib.escapeShellArg config.sops.secrets.${userCfg.passwordSecret}.path}'')
        cfg.users);

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
  options.alanix.navidrome = {
    enable = lib.mkEnableOption "Navidrome (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Bind address for Navidrome.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port for Navidrome.";
    };

    scanInterval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = "How often Navidrome scans the music folder for changes.";
    };

    purgeMissing = lib.mkOption {
      type = lib.types.enum [ "never" "always" "full" ];
      default = "never";
      description = ''
        When Navidrome should purge missing files from the database.
        Use "always" after every scan, "full" only after full scans, or "never" to preserve missing-file metadata.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/navidrome";
      description = "Navidrome data/state directory.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra groups granted to the Navidrome service user so it can read media files.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          admin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this user has Navidrome admin privileges.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.str;
            description = "Name of a sops secret containing the user's plaintext password.";
          };
        };
      }));
      default = { };
      description = ''
        Declarative Navidrome users. Passwords are read from sops secrets and
        enforced on every service restart via Navidrome's native HTTP API.
        The first declared admin user is used to bootstrap the initial admin account.
      '';
    };

    internetRadioStations = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Display name for this Navidrome internet radio station.";
          };

          streamUrl = lib.mkOption {
            type = lib.types.str;
            description = "Playable stream URL.";
          };

          homePageUrl = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Optional homepage URL shown for the station.";
          };
        };
      }));
      default = { };
      description = ''
        Declarative Navidrome internet radio stations. Declared stations are
        created or updated through Navidrome's Subsonic API; manually-created
        stations are left alone.
      '';
    };

    mediaFolders = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            description = "Absolute filesystem path.";
          };

          create = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to create the directory via systemd-tmpfiles.";
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
      description = "Filesystem directories made available to Navidrome. Must include a 'music' entry.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Navidrome through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "12h";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "48h";
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "navidrome";
      serviceDescription = "Navidrome";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.navidrome.listenAddress must be set when alanix.navidrome.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.navidrome.port must be set when alanix.navidrome.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.navidrome.dataDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.navidrome.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.navidrome.cluster.enable requires alanix.navidrome.backupDir to be set.";
          }
          {
            assertion = cfg.mediaFolders ? music;
            message = "alanix.navidrome.mediaFolders must include a 'music' entry (used as MusicFolder).";
          }
          {
            assertion = !baseConfigReady || bootstrapAdminName != null;
            message = "alanix.navidrome.users must include at least one admin user.";
          }
        ]
        ++ lib.flatten (
          lib.mapAttrsToList
            (uname: userCfg: [
              {
                assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
                message = "alanix.navidrome.users.${uname}.passwordSecret '${userCfg.passwordSecret}' must be declared as a sops secret.";
              }
            ])
            cfg.users
        )
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.navidrome.expose";
        }
        ++ lib.flatten (
          lib.mapAttrsToList
            (folderName: folderCfg: [
              {
                assertion = lib.hasPrefix "/" folderCfg.path;
                message = "alanix.navidrome.mediaFolders.${folderName}.path must be an absolute path.";
              }
            ])
            cfg.mediaFolders
        );

      services.navidrome = lib.mkIf baseConfigReady {
        enable = true;
        settings = {
          Address = cfg.listenAddress;
          Port = cfg.port;
          DataFolder = cfg.dataDir;
          MusicFolder = cfg.mediaFolders.music.path;
          ScanInterval = cfg.scanInterval;
          Scanner.PurgeMissing = cfg.purgeMissing;
          LogLevel = "info";
          EnableInsightsCollector = false;
        };
        openFirewall = false;
      };

      users.users.${config.services.navidrome.user}.extraGroups = cfg.extraGroups;

      systemd.services.navidrome-reconcile-users =
        lib.mkIf (reconcileEnabled && baseConfigReady) {
          description = "Reconcile Navidrome users";
          after = [ "navidrome.service" "sops-nix.service" ];
          wants = [ "navidrome.service" "sops-nix.service" ];
          partOf = [ "navidrome.service" ];
          wantedBy = [ "navidrome.service" ];

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";
            UMask = "0077";
            SuccessExitStatus = [ "SIGTERM" ];
          };

          path = [ pkgs.coreutils pkgs.curl pkgs.jq ];

          script = ''
            set -euo pipefail

            BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}
            ADMIN_USER=${lib.escapeShellArg (if bootstrapAdminName == null then "" else bootstrapAdminName)}
            ADMIN_PASSFILE=${lib.escapeShellArg adminPassfilePath}

            ${passfileLines}

            RESPONSE_STATUS=""
            RESPONSE_BODY=""

            wait_for_server() {
              local attempts=120
              while [ "$attempts" -gt 0 ]; do
                if curl -sf "$BASE_URL/app/" >/dev/null 2>&1; then
                  return 0
                fi
                sleep 1
                attempts=$((attempts - 1))
              done
              echo "Timed out waiting for Navidrome to become ready." >&2
              return 1
            }

            http_json() {
              local method="$1"
              local path="$2"
              local payload="''${3:-}"
              local token="''${4:-}"
              local body_file
              local curl_args

              body_file="$(mktemp)"
              curl_args=(
                -sS
                -o
                "$body_file"
                -w
                "%{http_code}"
                -X
                "$method"
                "$BASE_URL$path"
                -H
                "Content-Type: application/json"
              )
              if [ -n "$token" ]; then
                curl_args+=(-H "X-ND-Authorization: Bearer $token")
              fi
              if [ -n "$payload" ]; then
                curl_args+=(--data "$payload")
              fi

              RESPONSE_STATUS="$(curl "''${curl_args[@]}" || true)"
              RESPONSE_BODY="$(cat "$body_file")"
              rm -f "$body_file"
            }

            is_success_status() {
              [ "$1" = "200" ] || [ "$1" = "201" ]
            }

            auth_payload() {
              local username="$1"
              local password="$2"
              jq -cn \
                --arg username "$username" \
                --arg password "$password" \
                '{ username: $username, password: $password }'
            }

            user_payload() {
              local username="$1"
              local password="$2"
              local want_admin="$3"
              local name="$4"
              local email="$5"
              local current_password="''${6:-}"
              jq -cn \
                --arg userName "$username" \
                --arg password "$password" \
                --arg name "$name" \
                --arg email "$email" \
                --arg currentPassword "$current_password" \
                --argjson isAdmin "$want_admin" \
                '{
                  userName: $userName,
                  password: $password,
                  name: $name,
                  email: $email,
                  isAdmin: $isAdmin
                } + (if $currentPassword != "" then { currentPassword: $currentPassword } else {} end)'
            }

            login_or_bootstrap_admin() {
              local password payload token login_status create_status

              password="$(tr -d '\r\n' < "$ADMIN_PASSFILE")"
              payload="$(auth_payload "$ADMIN_USER" "$password")"

              http_json POST "/auth/login" "$payload"
              login_status="$RESPONSE_STATUS"
              if is_success_status "$login_status"; then
                token="$(printf '%s' "$RESPONSE_BODY" | jq -r '.token // empty')"
                if [ -n "$token" ]; then
                  printf '%s' "$token"
                  return 0
                fi
              fi

              http_json POST "/auth/createAdmin" "$payload"
              create_status="$RESPONSE_STATUS"
              if is_success_status "$create_status"; then
                token="$(printf '%s' "$RESPONSE_BODY" | jq -r '.token // empty')"
                if [ -n "$token" ]; then
                  echo "Bootstrapped initial Navidrome admin: $ADMIN_USER" >&2
                  printf '%s' "$token"
                  return 0
                fi
              fi

              echo "Warning: Unable to authenticate or bootstrap the declared Navidrome admin user '$ADMIN_USER'." >&2
              echo "Login status: $login_status; createAdmin status: $create_status" >&2
              if [ "$create_status" = "403" ]; then
                echo "Navidrome already has users, but the declared admin password could not log in." >&2
              fi
              return 1
            }

            get_users() {
              local token="$1"

              http_json GET "/api/user/" "" "$token"
              if ! is_success_status "$RESPONSE_STATUS"; then
                echo "Warning: Unable to list Navidrome users (HTTP $RESPONSE_STATUS)." >&2
                return 1
              fi

              printf '%s' "$RESPONSE_BODY"
            }

            ensure_user() {
              local username="$1"
              local passfile="$2"
              local want_admin="$3"
              local token="$4"
              local pass users_response user_json user_id current_name current_email payload

              pass="$(tr -d '\r\n' < "$passfile")"
              users_response="$(get_users "$token" || true)"
              if [ -z "$users_response" ]; then
                return 0
              fi
              user_json="$(printf '%s' "$users_response" | jq -c --arg u "$username" '.[] | select(.userName == $u)' | head -n 1)"

              if [ -z "$user_json" ]; then
                echo "Creating Navidrome user: $username"
                payload="$(user_payload "$username" "$pass" "$want_admin" "$username" "")"
                http_json POST "/api/user/" "$payload" "$token"
                if ! is_success_status "$RESPONSE_STATUS"; then
                  echo "Warning: Failed to create Navidrome user '$username' (HTTP $RESPONSE_STATUS)." >&2
                  printf '%s\n' "$RESPONSE_BODY" >&2
                fi
              else
                echo "Reconciling Navidrome user: $username"
                user_id="$(printf '%s' "$user_json" | jq -r '.id')"
                current_name="$(printf '%s' "$user_json" | jq -r '.name // ""')"
                current_email="$(printf '%s' "$user_json" | jq -r '.email // ""')"
                payload="$(user_payload "$username" "$pass" "$want_admin" "$current_name" "$current_email" "$pass")"
                http_json PUT "/api/user/$user_id/" "$payload" "$token"
                if ! is_success_status "$RESPONSE_STATUS"; then
                  echo "Warning: Failed to reconcile Navidrome user '$username' (HTTP $RESPONSE_STATUS)." >&2
                  printf '%s\n' "$RESPONSE_BODY" >&2
                fi
              fi
            }

            wait_for_server

            token="$(login_or_bootstrap_admin || true)"
            if [ -z "''${token:-}" ]; then
              exit 0
            fi

            ${lib.concatStringsSep "\n"
              (lib.mapAttrsToList
                (uname: userCfg:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                    wantAdmin = if userCfg.admin then "true" else "false";
                  in
                  ''ensure_user ${lib.escapeShellArg uname} "${"$"}${var}" ${wantAdmin} "$token"'')
                cfg.users)}

            echo "Navidrome user reconciliation complete."
          '';

          restartTriggers = [ (builtins.toJSON sanitizedUsersForRestart) ];
        };

      systemd.services.navidrome-reconcile-internet-radios =
        lib.mkIf (radioReconcileEnabled && baseConfigReady) {
          description = "Reconcile Navidrome internet radio stations";
          after = [ "navidrome.service" "navidrome-reconcile-users.service" "sops-nix.service" ];
          wants = [ "navidrome.service" "navidrome-reconcile-users.service" "sops-nix.service" ];
          partOf = [ "navidrome.service" ];
          wantedBy = [ "navidrome.service" ];

          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";
            UMask = "0077";
          };

          path = [ pkgs.coreutils pkgs.curl pkgs.jq ];

          script = ''
            set -euo pipefail

            BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}
            ADMIN_USER=${lib.escapeShellArg (if bootstrapAdminName == null then "" else bootstrapAdminName)}
            ADMIN_PASSFILE=${lib.escapeShellArg adminPassfilePath}

            RESPONSE_STATUS=""
            RESPONSE_BODY=""

            wait_for_server() {
              local attempts=120
              while [ "$attempts" -gt 0 ]; do
                if curl -sf "$BASE_URL/app/" >/dev/null 2>&1; then
                  return 0
                fi
                sleep 1
                attempts=$((attempts - 1))
              done
              echo "Timed out waiting for Navidrome to become ready." >&2
              return 1
            }

            subsonic_call() {
              local endpoint="$1"
              shift
              local body_file
              local curl_args

              body_file="$(mktemp)"
              curl_args=(
                -sS
                -o
                "$body_file"
                -w
                "%{http_code}"
                -G
                "$BASE_URL/rest/$endpoint.view"
                --data-urlencode
                "u=$ADMIN_USER"
                --data-urlencode
                "p=$ADMIN_PASSWORD"
                --data-urlencode
                "v=1.16.1"
                --data-urlencode
                "c=alanix-navidrome"
                --data-urlencode
                "f=json"
              )

              while [ "$#" -gt 0 ]; do
                curl_args+=(--data-urlencode "$1")
                shift
              done

              RESPONSE_STATUS="$(curl "''${curl_args[@]}" || true)"
              RESPONSE_BODY="$(cat "$body_file")"
              rm -f "$body_file"
            }

            is_success_status() {
              [ "$1" = "200" ] || [ "$1" = "201" ]
            }

            subsonic_ok() {
              is_success_status "$RESPONSE_STATUS" \
                && [ "$(printf '%s' "$RESPONSE_BODY" | jq -r '.status // empty')" = "ok" ]
            }

            warn_subsonic_failure() {
              local action="$1"
              local message

              message="$(printf '%s' "$RESPONSE_BODY" | jq -r '.error.message // empty' 2>/dev/null || true)"
              echo "Warning: Failed to $action (HTTP $RESPONSE_STATUS). ''${message}" >&2
              if [ -n "$RESPONSE_BODY" ]; then
                printf '%s\n' "$RESPONSE_BODY" >&2
              fi
            }

            get_radios() {
              subsonic_call getInternetRadioStations
              if ! subsonic_ok; then
                warn_subsonic_failure "list Navidrome internet radio stations"
                return 1
              fi

              printf '%s' "$RESPONSE_BODY"
            }

            ensure_radio() {
              local radio_key="$1"
              local radio_name="$2"
              local stream_url="$3"
              local homepage_url="$4"
              local radios_response existing radio_id current_name current_stream current_home

              radios_response="$(get_radios || true)"
              if [ -z "$radios_response" ]; then
                return 0
              fi

              existing="$(
                printf '%s' "$radios_response" \
                  | jq -c \
                    --arg name "$radio_name" \
                    --arg streamUrl "$stream_url" \
                    '.internetRadioStations.internetRadioStation // [] | map(select(.name == $name or .streamUrl == $streamUrl)) | .[0] // empty'
              )"

              if [ -z "$existing" ]; then
                echo "Creating Navidrome internet radio station: $radio_name"
                subsonic_call createInternetRadioStation \
                  "name=$radio_name" \
                  "streamUrl=$stream_url" \
                  "homepageUrl=$homepage_url"
                if ! subsonic_ok; then
                  warn_subsonic_failure "create Navidrome internet radio station '$radio_key'"
                fi
                return 0
              fi

              radio_id="$(printf '%s' "$existing" | jq -r '.id')"
              current_name="$(printf '%s' "$existing" | jq -r '.name // ""')"
              current_stream="$(printf '%s' "$existing" | jq -r '.streamUrl // ""')"
              current_home="$(printf '%s' "$existing" | jq -r '.homePageUrl // ""')"

              if [ "$current_name" = "$radio_name" ] \
                && [ "$current_stream" = "$stream_url" ] \
                && [ "$current_home" = "$homepage_url" ]; then
                echo "Navidrome internet radio station already current: $radio_name"
                return 0
              fi

              echo "Updating Navidrome internet radio station: $radio_name"
              subsonic_call updateInternetRadioStation \
                "id=$radio_id" \
                "name=$radio_name" \
                "streamUrl=$stream_url" \
                "homepageUrl=$homepage_url"
              if ! subsonic_ok; then
                warn_subsonic_failure "update Navidrome internet radio station '$radio_key'"
              fi
            }

            wait_for_server

            ADMIN_PASSWORD="$(tr -d '\r\n' < "$ADMIN_PASSFILE")"

            ${lib.concatStringsSep "\n"
              (lib.mapAttrsToList
                (radioKey: radioCfg:
                  ''ensure_radio ${lib.escapeShellArg radioKey} ${lib.escapeShellArg radioCfg.name} ${lib.escapeShellArg radioCfg.streamUrl} ${lib.escapeShellArg radioCfg.homePageUrl}'')
                cfg.internetRadioStations)}

            echo "Navidrome internet radio reconciliation complete."
          '';

          restartTriggers = [ (builtins.toJSON sanitizedRadiosForRestart) ];
        };

      system.activationScripts.alanixNavidromeReconcile =
        lib.mkIf (baseConfigReady && (reconcileEnabled || radioReconcileEnabled)) ''
          if ${pkgs.systemd}/bin/systemctl --quiet is-active navidrome.service; then
            ${lib.optionalString reconcileEnabled ''
              ${pkgs.systemd}/bin/systemctl start navidrome-reconcile-users.service || true
            ''}
            ${lib.optionalString radioReconcileEnabled ''
              ${pkgs.systemd}/bin/systemctl start navidrome-reconcile-internet-radios.service || true
            ''}
          fi
        '';

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady mediaTmpfilesRules;
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "navidrome";
        serviceDescription = "Navidrome";
      }
    ))
  ]);
}
