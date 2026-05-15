{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.audiobookshelf;
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

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;
  stateDirectoryName = lib.removePrefix "/var/lib/" cfg.dataDir;

  adminUsers = lib.filterAttrs (_: userCfg: userCfg.admin) cfg.users;
  adminUserNames = builtins.attrNames adminUsers;
  bootstrapAdminName = if adminUserNames == [ ] then null else builtins.head adminUserNames;
  reconcileEnabled = cfg.users != { };

  sanitizedUsersForRestart =
    lib.mapAttrs (_: userCfg: { inherit (userCfg) admin email passwordSecret; }) cfg.users;

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
  options.alanix.audiobookshelf = {
    enable = lib.mkEnableOption "Audiobookshelf (Alanix)";

    package = lib.mkPackageOption pkgs "audiobookshelf" { };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Bind address for Audiobookshelf.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port for Audiobookshelf.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/audiobookshelf";
      description = "Audiobookshelf data/state directory. Must live under /var/lib.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra groups granted to the Audiobookshelf service user so it can read media files.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          admin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this user has Audiobookshelf admin privileges.";
          };

          email = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional email address for this Audiobookshelf user.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.str;
            description = "Name of a sops secret containing the user's plaintext password.";
          };
        };
      }));
      default = { };
      description = ''
        Declarative Audiobookshelf users. Passwords are read from sops secrets
        and enforced on every service restart through Audiobookshelf's HTTP API.
        The first declared admin user initializes the root account on first boot.
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
      description = "Filesystem directories made available to Audiobookshelf.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Audiobookshelf through alanix.cluster";

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
      serviceName = "audiobookshelf";
      serviceDescription = "Audiobookshelf";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.audiobookshelf.listenAddress must be set when alanix.audiobookshelf.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.audiobookshelf.port must be set when alanix.audiobookshelf.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/var/lib/" cfg.dataDir && stateDirectoryName != "";
            message = "alanix.audiobookshelf.dataDir must be an absolute path under /var/lib.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.audiobookshelf.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.audiobookshelf.cluster.enable requires alanix.audiobookshelf.backupDir to be set.";
          }
          {
            assertion = !reconcileEnabled || bootstrapAdminName != null;
            message = "alanix.audiobookshelf.users must include at least one admin user when non-empty.";
          }
        ]
        ++ lib.flatten (
          lib.mapAttrsToList
            (uname: userCfg: [
              {
                assertion = builtins.match "^[A-Za-z0-9._@+-]+$" uname != null;
                message = "alanix.audiobookshelf.users.${uname}: username may only contain letters, numbers, dots, underscores, at signs, plus signs, and dashes.";
              }
              {
                assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
                message = "alanix.audiobookshelf.users.${uname}.passwordSecret '${userCfg.passwordSecret}' must be declared as a sops secret.";
              }
            ])
            cfg.users
        )
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.audiobookshelf.expose";
        }
        ++ lib.flatten (
          lib.mapAttrsToList
            (folderName: folderCfg: [
              {
                assertion = lib.hasPrefix "/" folderCfg.path;
                message = "alanix.audiobookshelf.mediaFolders.${folderName}.path must be an absolute path.";
              }
            ])
            cfg.mediaFolders
        );

      services.audiobookshelf = lib.mkIf baseConfigReady {
        enable = true;
        package = cfg.package;
        host = cfg.listenAddress;
        port = cfg.port;
        dataDir = stateDirectoryName;
        openFirewall = false;
      };

      users.users.${config.services.audiobookshelf.user}.extraGroups = cfg.extraGroups;

      systemd.services.audiobookshelf-reconcile-users =
        lib.mkIf (reconcileEnabled && baseConfigReady) {
          description = "Reconcile Audiobookshelf users";
          after = [ "audiobookshelf.service" "sops-nix.service" ];
          wants = [ "audiobookshelf.service" "sops-nix.service" ];
          partOf = [ "audiobookshelf.service" ];
          wantedBy = [ "audiobookshelf.service" ];

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
            LOGIN_TOKEN=""

            wait_for_server() {
              local attempts=120
              while [ "$attempts" -gt 0 ]; do
                if curl -sf "$BASE_URL/status" | jq -e '.app == "audiobookshelf"' >/dev/null 2>&1; then
                  return 0
                fi
                sleep 1
                attempts=$((attempts - 1))
              done
              echo "Timed out waiting for Audiobookshelf to become ready." >&2
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
                curl_args+=(-H "Authorization: Bearer $token")
              fi
              if [ -n "$payload" ]; then
                curl_args+=(--data "$payload")
              fi

              RESPONSE_STATUS="$(curl "''${curl_args[@]}" || true)"
              RESPONSE_BODY="$(cat "$body_file")"
              rm -f "$body_file"
            }

            is_success_status() {
              [ "$1" = "200" ] || [ "$1" = "201" ] || [ "$1" = "204" ]
            }

            auth_payload() {
              local username="$1"
              local password="$2"
              jq -cn \
                --arg username "$username" \
                --arg password "$password" \
                '{ username: $username, password: $password }'
            }

            init_payload() {
              local username="$1"
              local password="$2"
              jq -cn \
                --arg username "$username" \
                --arg password "$password" \
                '{ newRoot: { username: $username, password: $password } }'
            }

            create_user_payload() {
              local username="$1"
              local password="$2"
              local account_type="$3"
              local email="$4"
              jq -cn \
                --arg username "$username" \
                --arg password "$password" \
                --arg accountType "$account_type" \
                --arg email "$email" \
                '{
                  username: $username,
                  password: $password,
                  type: $accountType,
                  isActive: true
                } + (if $email != "" then { email: $email } else {} end)'
            }

            update_user_payload() {
              local password="$1"
              local account_type="$2"
              local email="$3"
              local current_type="$4"
              jq -cn \
                --arg password "$password" \
                --arg accountType "$account_type" \
                --arg email "$email" \
                --arg currentType "$current_type" \
                '{
                  password: $password,
                  isActive: true
                }
                + (if $currentType != "root" then { type: $accountType } else {} end)
                + (if $email != "" then { email: $email } else {} end)'
            }

            login_admin() {
              local password payload token

              LOGIN_TOKEN=""
              password="$(tr -d '\r\n' < "$ADMIN_PASSFILE")"
              payload="$(auth_payload "$ADMIN_USER" "$password")"

              http_json POST "/login" "$payload"
              if is_success_status "$RESPONSE_STATUS"; then
                token="$(printf '%s' "$RESPONSE_BODY" | jq -r '.user.accessToken // .user.token // empty')"
                if [ -n "$token" ]; then
                  LOGIN_TOKEN="$token"
                  return 0
                fi
              fi

              return 1
            }

            login_or_bootstrap_admin() {
              local password payload login_status init_status is_init

              if login_admin; then
                printf '%s' "$LOGIN_TOKEN"
                return 0
              fi
              login_status="$RESPONSE_STATUS"

              http_json GET "/status"
              if ! is_success_status "$RESPONSE_STATUS"; then
                echo "Warning: Unable to read Audiobookshelf status (HTTP $RESPONSE_STATUS)." >&2
                return 1
              fi

              is_init="$(printf '%s' "$RESPONSE_BODY" | jq -r '.isInit // false')"
              if [ "$is_init" != "false" ]; then
                echo "Warning: Unable to authenticate declared Audiobookshelf admin user '$ADMIN_USER'." >&2
                echo "Login status: $login_status. The server is already initialized." >&2
                return 1
              fi

              password="$(tr -d '\r\n' < "$ADMIN_PASSFILE")"
              payload="$(init_payload "$ADMIN_USER" "$password")"
              http_json POST "/init" "$payload"
              init_status="$RESPONSE_STATUS"
              if ! is_success_status "$init_status"; then
                echo "Warning: Failed to initialize Audiobookshelf root user '$ADMIN_USER' (HTTP $init_status)." >&2
                printf '%s\n' "$RESPONSE_BODY" >&2
                return 1
              fi

              if login_admin; then
                echo "Bootstrapped initial Audiobookshelf root user: $ADMIN_USER" >&2
                printf '%s' "$LOGIN_TOKEN"
                return 0
              fi

              echo "Warning: Audiobookshelf initialized, but the declared admin user '$ADMIN_USER' could not log in." >&2
              return 1
            }

            get_users() {
              local token="$1"

              http_json GET "/api/users" "" "$token"
              if ! is_success_status "$RESPONSE_STATUS"; then
                echo "Warning: Unable to list Audiobookshelf users (HTTP $RESPONSE_STATUS)." >&2
                printf '%s\n' "$RESPONSE_BODY" >&2
                return 1
              fi

              printf '%s' "$RESPONSE_BODY"
            }

            ensure_user() {
              local username="$1"
              local passfile="$2"
              local want_admin="$3"
              local email="$4"
              local token="$5"
              local pass users_response user_json user_id current_type account_type payload

              pass="$(tr -d '\r\n' < "$passfile")"
              if [ "$want_admin" = "true" ]; then
                account_type="admin"
              else
                account_type="user"
              fi

              users_response="$(get_users "$token" || true)"
              if [ -z "$users_response" ]; then
                return 0
              fi
              user_json="$(printf '%s' "$users_response" | jq -c --arg u "$username" '.users[] | select(.username == $u)' | head -n 1)"

              if [ -z "$user_json" ]; then
                echo "Creating Audiobookshelf user: $username"
                payload="$(create_user_payload "$username" "$pass" "$account_type" "$email")"
                http_json POST "/api/users" "$payload" "$token"
                if ! is_success_status "$RESPONSE_STATUS"; then
                  echo "Warning: Failed to create Audiobookshelf user '$username' (HTTP $RESPONSE_STATUS)." >&2
                  printf '%s\n' "$RESPONSE_BODY" >&2
                fi
              else
                echo "Reconciling Audiobookshelf user: $username"
                user_id="$(printf '%s' "$user_json" | jq -r '.id')"
                current_type="$(printf '%s' "$user_json" | jq -r '.type // ""')"
                payload="$(update_user_payload "$pass" "$account_type" "$email" "$current_type")"
                http_json PATCH "/api/users/$user_id" "$payload" "$token"
                if ! is_success_status "$RESPONSE_STATUS"; then
                  echo "Warning: Failed to reconcile Audiobookshelf user '$username' (HTTP $RESPONSE_STATUS)." >&2
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
                    email = if userCfg.email == null then "" else userCfg.email;
                  in
                  ''ensure_user ${lib.escapeShellArg uname} "${"$"}${var}" ${wantAdmin} ${lib.escapeShellArg email} "$token"'')
                cfg.users)}

            echo "Audiobookshelf user reconciliation complete."
          '';

          restartTriggers = [ (builtins.toJSON sanitizedUsersForRestart) ];
        };

      system.activationScripts.alanixAudiobookshelfReconcile =
        lib.mkIf (baseConfigReady && reconcileEnabled) {
          deps = [ "etc" ];
          text = ''
            if ${pkgs.systemd}/bin/systemctl --quiet is-active audiobookshelf.service; then
              ${pkgs.systemd}/bin/systemctl daemon-reload
              ${pkgs.systemd}/bin/systemctl start audiobookshelf-reconcile-users.service || true
            fi
          '';
        };

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady mediaTmpfilesRules;
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "audiobookshelf";
        serviceDescription = "Audiobookshelf";
      }
    ))
  ]);
}
