{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.immich;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  passwordUsers = import ../../lib/mkPlaintextPasswordUsers.nix { inherit lib; };
  serviceIdentity = import ../../lib/mkServiceIdentity.nix { inherit lib; };

  exposeCfg = cfg.expose;
  inherit (passwordUsers) hasValue;

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;

  declaredEmails = lib.mapAttrsToList (_: userCfg: userCfg.email) cfg.users;
  declaredEmailList = lib.concatStringsSep " " declaredEmails;
  declaredEmailLines = lib.concatStringsSep "\n" declaredEmails;
  declaredStorageLabels =
    lib.filter
      (storageLabel: storageLabel != null && storageLabel != "")
      (lib.mapAttrsToList (_: userCfg: userCfg.storageLabel) cfg.users);

  adminUsers = lib.filterAttrs (_: userCfg: userCfg.admin) cfg.users;
  adminUserNames = builtins.attrNames adminUsers;
  declaredAdminEmails = lib.mapAttrsToList (_: userCfg: userCfg.email) adminUsers;
  declaredAdminEmailLines = lib.concatStringsSep "\n" declaredAdminEmails;

  sanitizeUserKey = name: lib.replaceStrings [ "-" "." "@" "+" ] [ "_" "_" "_" "_" ] name;

  bootstrapAdminName = if adminUserNames == [ ] then null else builtins.head adminUserNames;
  bootstrapAdmin = if bootstrapAdminName == null then null else adminUsers.${bootstrapAdminName};
  bootstrapAdminEmail = if bootstrapAdmin == null then "" else bootstrapAdmin.email;
  bootstrapAdminDisplayName = if bootstrapAdmin == null then "" else bootstrapAdmin.name;
  bootstrapPassVar = if bootstrapAdminName == null then "" else "PASSFILE_" + sanitizeUserKey bootstrapAdminName;

  effectiveExternalDomain =
    let
      rootUrl = serviceIdentity.rootUrl {
        inherit config exposeCfg;
        listenAddress = cfg.listenAddress;
        port = cfg.port;
        rootUrlOverride = cfg.externalDomain;
      };
    in
    if rootUrl == null then "" else lib.removeSuffix "/" rootUrl;

  defaultSettings = {
    newVersionCheck.enabled = false;
    passwordLogin.enabled = true;
    server = {
      externalDomain = effectiveExternalDomain;
      publicUsers = cfg.publicUsers;
    };
  };

  sanitizedUsersForRestart = passwordUsers.sanitizeForRestart {
    users = cfg.users;
    inheritFields = [
      "admin"
      "email"
      "name"
      "passwordSecret"
      "quotaSizeInBytes"
      "shouldChangePassword"
      "storageLabel"
    ];
  };
in
{
  options.alanix.immich = {
    enable = lib.mkEnableOption "Immich (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Immich cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Immich through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };
    };

    mediaLocation = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/immich";
      description = "Directory used to store Immich media.";
    };

    externalDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public URL advertised by Immich, including http:// or https://.";
    };

    publicUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether Immich should enable public user accounts.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional environment file passed to services.immich.secretsFile for non-store secrets such as DB_PASSWORD.";
    };

    accelerationDevices = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = [ ];
      description = "Hardware acceleration devices passed through to services.immich.accelerationDevices.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra Immich server environment variables.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.immich.settings merged on top of the Alanix defaults.";
    };

    machineLearning = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra Immich machine-learning environment variables.";
      };
    };

    pruneUndeclaredUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete Immich users that are not present in alanix.immich.users.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = passwordUsers.mkOptions {
          extraOptions = {
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            email = lib.mkOption {
              type = lib.types.str;
              description = "Email address for the Immich user.";
            };

            name = lib.mkOption {
              type = lib.types.str;
              description = "Display name for the Immich user.";
            };

            shouldChangePassword = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            storageLabel = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };

            quotaSizeInBytes = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
          };
        };
      }));
      default = { };
      description = "Declarative Immich users keyed by a local label; reconciliation matches them by email.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "immich";
      serviceDescription = "Immich";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.immich: users must not be empty when enable = true.";
          }
          {
            assertion = lib.length declaredAdminEmails > 0;
            message = "alanix.immich: at least one declared user must have admin = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.immich.listenAddress must be set when alanix.immich.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.immich.port must be set when alanix.immich.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" (toString cfg.mediaLocation);
            message = "alanix.immich.mediaLocation must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.immich.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.immich.cluster.enable requires alanix.immich.backupDir to be set.";
          }
          {
            assertion = cfg.externalDomain == null || builtins.match "^https?://.+" cfg.externalDomain != null;
            message = "alanix.immich.externalDomain must include http:// or https://.";
          }
          {
            assertion = cfg.secretsFile == null || lib.hasPrefix "/" cfg.secretsFile;
            message = "alanix.immich.secretsFile must be an absolute path when set.";
          }
          {
            assertion = !(lib.hasAttrByPath [ "passwordLogin" "enabled" ] cfg.settings) || cfg.settings.passwordLogin.enabled;
            message = "alanix.immich.settings.passwordLogin.enabled must not be false when declarative users are enabled.";
          }
          {
            assertion = lib.length declaredEmails == lib.length (lib.unique declaredEmails);
            message = "alanix.immich.users.*.email must be unique.";
          }
          {
            assertion = lib.length declaredStorageLabels == lib.length (lib.unique declaredStorageLabels);
            message = "alanix.immich.users.*.storageLabel must be unique when set.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.immich.expose";
        }
        ++ passwordUsers.mkAssertions {
          inherit config;
          users = cfg.users;
          usernamePattern = "^[A-Za-z0-9._-]+$";
          usernameMessage = uname: "alanix.immich.users.${uname}: local labels may contain only letters, digits, dot, underscore, and hyphen.";
          passwordSourceMessage = uname: "alanix.immich.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          passwordSecretMessage = uname: "alanix.immich.users.${uname}.passwordSecret must reference a declared sops secret.";
          extraAssertions = uname: u: [
            {
              assertion = hasValue u.email;
              message = "alanix.immich.users.${uname}.email must be set.";
            }
            {
              assertion = hasValue u.name;
              message = "alanix.immich.users.${uname}.name must be set.";
            }
            {
              assertion = u.quotaSizeInBytes == null || u.quotaSizeInBytes >= 0;
              message = "alanix.immich.users.${uname}.quotaSizeInBytes must be null or a non-negative integer.";
            }
          ];
        };

      services.immich = lib.mkIf baseConfigReady {
        enable = true;
        host = cfg.listenAddress;
        port = cfg.port;
        mediaLocation = cfg.mediaLocation;
        secretsFile = cfg.secretsFile;
        accelerationDevices = cfg.accelerationDevices;
        environment = cfg.environment;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
        machine-learning = {
          enable = cfg.machineLearning.enable;
          environment = cfg.machineLearning.environment;
        };
      };

      systemd.services.immich-reconcile-users = lib.mkIf (cfg.users != { } && baseConfigReady) {
        description = "Reconcile Immich users (create declared; optionally prune undeclared)";
        after = [ "immich-server.service" "sops-nix.service" ];
        wants = [ "immich-server.service" "sops-nix.service" ];
        partOf = [ "immich-server.service" ];
        wantedBy = [ "immich-server.service" ];

        serviceConfig =
          {
            Type = "oneshot";
            SuccessExitStatus = [ "SIGTERM" ];
            User = config.services.immich.user;
            Group = config.services.immich.group;
            WorkingDirectory = "/var/lib/immich";
            RuntimeDirectory = "alanix-immich";
            RuntimeDirectoryMode = "0700";
            UMask = "0077";
          }
          // lib.optionalAttrs (cfg.secretsFile != null) {
            EnvironmentFile = cfg.secretsFile;
          }
          // lib.optionalAttrs
            (config.services.immich.redis.enable && lib.hasPrefix "/" config.services.immich.redis.host)
            {
              SupplementaryGroups = [ config.services.redis.servers.immich.group ];
            };

        environment = config.services.immich.environment // {
          HOME = "/var/lib/immich";
        };

        path = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.openssl
        ];

        script =
          let
            passfileLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: u:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                    runtimePassfile = "$RUNTIME_DIRECTORY/${sanitizeUserKey uname}.pass";
                  in
                  if u.passwordFile != null then
                    ''${var}=${lib.escapeShellArg (toString u.passwordFile)}''
                  else if u.passwordSecret != null then
                    ''${var}=${lib.escapeShellArg config.sops.secrets.${u.passwordSecret}.path}''
                  else
                    ''${var}=${lib.escapeShellArg runtimePassfile}; ensure_runtime_passfile "${"$"}${var}" ${lib.escapeShellArg u.password}''
                ) cfg.users);

            loginDeclaredAdminLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: u:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                  in
                  lib.optionalString u.admin ''
                    if token="$(login_with_password ${lib.escapeShellArg u.email} "${"$"}${var}")"; then
                      ACTING_TOKEN="$token"
                      ACTING_EMAIL=${lib.escapeShellArg u.email}
                      return 0
                    fi
                  ''
                ) cfg.users);

            ensureLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: u:
                  let
                    var = "PASSFILE_" + sanitizeUserKey uname;
                    storageLabelJson =
                      if u.storageLabel == null then "null" else builtins.toJSON u.storageLabel;
                    quotaJson =
                      if u.quotaSizeInBytes == null then "null" else builtins.toString u.quotaSizeInBytes;
                  in
                  ''ensure_user ${lib.escapeShellArg u.email} ${lib.escapeShellArg u.name} "${"$"}${var}" ${if u.admin then "true" else "false"} ${if u.shouldChangePassword then "true" else "false"} ${lib.escapeShellArg storageLabelJson} ${lib.escapeShellArg quotaJson}''
                ) cfg.users);
          in
          ''
            set -euo pipefail

            BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}
            DECLARED_EMAILS=${lib.escapeShellArg declaredEmailList}
            DECLARED_EMAIL_LINES=${lib.escapeShellArg declaredEmailLines}
            DECLARED_ADMIN_EMAIL_LINES=${lib.escapeShellArg declaredAdminEmailLines}
            PRUNE=${if cfg.pruneUndeclaredUsers then "1" else "0"}
            IMMICH_ADMIN=${lib.escapeShellArg (lib.getExe' config.services.immich.package "immich-admin")}
            BOOTSTRAP_EMAIL=${lib.escapeShellArg bootstrapAdminEmail}
            BOOTSTRAP_NAME=${lib.escapeShellArg bootstrapAdminDisplayName}
            BOOTSTRAP_PASSVAR=${lib.escapeShellArg bootstrapPassVar}

            ensure_runtime_passfile() {
              local path="$1"
              local value="$2"
              umask 077
              printf '%s' "$value" > "$path"
            }

            public_post_json() {
              local path="$1"
              local body="$2"
              curl -sS -f \
                -H 'Content-Type: application/json' \
                -X POST \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_get() {
              local path="$1"
              local token="$2"
              curl -sS -f \
                -H "Cookie: immich_access_token=$token" \
                "$BASE_URL$path"
            }

            api_post_json() {
              local path="$1"
              local body="$2"
              local token="$3"
              curl -sS -f \
                -H 'Content-Type: application/json' \
                -H "Cookie: immich_access_token=$token" \
                -X POST \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_post_empty() {
              local path="$1"
              local token="$2"
              curl -sS -f \
                -H "Cookie: immich_access_token=$token" \
                -X POST \
                "$BASE_URL$path"
            }

            api_put_json() {
              local path="$1"
              local body="$2"
              local token="$3"
              curl -sS -f \
                -H 'Content-Type: application/json' \
                -H "Cookie: immich_access_token=$token" \
                -X PUT \
                -d "$body" \
                "$BASE_URL$path"
            }

            api_delete_json() {
              local path="$1"
              local body="$2"
              local token="$3"
              curl -sS -f \
                -H 'Content-Type: application/json' \
                -H "Cookie: immich_access_token=$token" \
                -X DELETE \
                -d "$body" \
                "$BASE_URL$path"
            }

            wait_for_server() {
              local attempts=120

              while [ "$attempts" -gt 0 ]; do
                if curl -sS -f "$BASE_URL/api/server/ping" >/dev/null 2>&1; then
                  return 0
                fi

                sleep 1
                attempts=$((attempts - 1))
              done

              echo "Timed out waiting for Immich to become ready." >&2
              return 1
            }

            login_with_inline_password() {
              local email="$1"
              local password="$2"
              local payload
              local response

              payload="$(jq -n --arg email "$email" --arg password "$password" '{ email: $email, password: $password }')"
              response="$(public_post_json "/api/auth/login" "$payload" 2>/dev/null)" || return 1
              printf '%s' "$response" | jq -er '.accessToken'
            }

            login_with_password() {
              local email="$1"
              local passfile="$2"
              local password

              password="$(tr -d '\r\n' < "$passfile")"
              login_with_inline_password "$email" "$password"
            }

            cli_list_users() {
              "$IMMICH_ADMIN" list-users 2>&1 || true
            }

            has_any_user() {
              local output
              output="$(cli_list_users)"
              printf '%s\n' "$output" | grep -Fq "email: '"
            }

            output_has_email() {
              local output="$1"
              local email="$2"
              printf '%s\n' "$output" | grep -Fq "email: '$email'"
            }

            first_email_from_output() {
              local output="$1"
              printf '%s\n' "$output" | awk -F"'" '/email: / { print $2; exit }'
            }

            pick_admin_candidate_email() {
              local output="$1"
              local email

              while IFS= read -r email; do
                [ -n "$email" ] || continue
                if output_has_email "$output" "$email"; then
                  printf '%s\n' "$email"
                  return 0
                fi
              done <<EOF
$DECLARED_ADMIN_EMAIL_LINES
EOF

              while IFS= read -r email; do
                [ -n "$email" ] || continue
                if output_has_email "$output" "$email"; then
                  printf '%s\n' "$email"
                  return 0
                fi
              done <<EOF
$DECLARED_EMAIL_LINES
EOF

              first_email_from_output "$output"
            }

            grant_admin_by_email() {
              local email="$1"
              local output

              output="$(printf '%s\n' "$email" | "$IMMICH_ADMIN" grant-admin 2>&1 || true)"
              printf '%s\n' "$output" | grep -Fq "Admin access has been granted to"
            }

            reset_any_admin_password() {
              local password="$1"
              local output

              output="$(printf '%s\n' "$password" | "$IMMICH_ADMIN" reset-admin-password 2>&1 || true)"
              printf '%s\n' "$output" | awk -F= '
                /Email=/ {
                  print $2
                  exit
                }
              '
            }

            bootstrap_first_admin() {
              local bootstrap_password
              local payload

              bootstrap_password="$(tr -d '\r\n' < "''${!BOOTSTRAP_PASSVAR}")"
              payload="$(
                jq -n \
                  --arg email "$BOOTSTRAP_EMAIL" \
                  --arg name "$BOOTSTRAP_NAME" \
                  --arg password "$bootstrap_password" \
                  '{ email: $email, name: $name, password: $password }'
              )"

              echo "Bootstrapping first Immich admin: $BOOTSTRAP_EMAIL"
              public_post_json "/api/auth/admin-sign-up" "$payload" >/dev/null
            }

            try_declared_admin_logins() {
              local token

              ${loginDeclaredAdminLines}

              return 1
            }

            recover_admin_token() {
              local cli_output
              local candidate
              local recovered_email
              local recovery_password

              cli_output="$(cli_list_users)"
              recovery_password="$(openssl rand -hex 16)"
              recovered_email="$(reset_any_admin_password "$recovery_password")"

              if [ -z "$recovered_email" ]; then
                candidate="$(pick_admin_candidate_email "$cli_output")"
                [ -n "$candidate" ] || return 1

                echo "Granting temporary admin access to: $candidate"
                grant_admin_by_email "$candidate" >/dev/null || return 1

                recovery_password="$(openssl rand -hex 16)"
                recovered_email="$(reset_any_admin_password "$recovery_password")"
              fi

              [ -n "$recovered_email" ] || return 1

              ACTING_TOKEN="$(login_with_inline_password "$recovered_email" "$recovery_password")" || return 1
              ACTING_EMAIL="$recovered_email"
            }

            fetch_users_json() {
              local token="$1"
              api_get "/api/admin/users?withDeleted=true" "$token"
            }

            user_id_for_email() {
              local users_json="$1"
              local email="$2"

              printf '%s' "$users_json" | jq -r --arg email "$email" '.[] | select(.email == $email) | .id' | head -n1
            }

            user_deleted_for_email() {
              local users_json="$1"
              local email="$2"

              printf '%s' "$users_json" | jq -r --arg email "$email" '.[] | select(.email == $email) | (.deletedAt != null)' | head -n1
            }

            ensure_user() {
              local email="$1"
              local name="$2"
              local passfile="$3"
              local is_admin="$4"
              local should_change="$5"
              local storage_label_json="$6"
              local quota_json="$7"
              local password
              local payload
              local users_json
              local user_id
              local deleted

              password="$(tr -d '\r\n' < "$passfile")"
              payload="$(
                jq -n \
                  --arg email "$email" \
                  --arg name "$name" \
                  --arg password "$password" \
                  --argjson isAdmin "$is_admin" \
                  --argjson shouldChangePassword "$should_change" \
                  --argjson storageLabel "$storage_label_json" \
                  --argjson quotaSizeInBytes "$quota_json" \
                  '
                    {
                      email: $email,
                      name: $name,
                      password: $password,
                      isAdmin: $isAdmin,
                      shouldChangePassword: $shouldChangePassword
                    }
                    + (if $storageLabel == null then {} else { storageLabel: $storageLabel } end)
                    + (if $quotaSizeInBytes == null then {} else { quotaSizeInBytes: $quotaSizeInBytes } end)
                  '
              )"

              users_json="$(fetch_users_json "$ACTING_TOKEN")"
              user_id="$(user_id_for_email "$users_json" "$email")"

              if [ -n "$user_id" ]; then
                deleted="$(user_deleted_for_email "$users_json" "$email")"
                if [ "$deleted" = "true" ]; then
                  echo "Restoring deleted Immich user: $email"
                  api_post_empty "/api/admin/users/$user_id/restore" "$ACTING_TOKEN" >/dev/null
                fi

                echo "Updating Immich user: $email"
                api_put_json "/api/admin/users/$user_id" "$payload" "$ACTING_TOKEN" >/dev/null
                return 0
              fi

              echo "Creating Immich user: $email"
              api_post_json "/api/admin/users" "$payload" "$ACTING_TOKEN" >/dev/null
            }

            prune_undeclared_users() {
              local token="$1"
              local users_json
              local email
              local id
              local keep
              local declared

              users_json="$(fetch_users_json "$token")"
              printf '%s' "$users_json" | jq -c '.[] | select(.deletedAt == null)' | while read -r user; do
                [ -n "$user" ] || continue
                email="$(printf '%s' "$user" | jq -r '.email')"
                keep=0
                for declared in $DECLARED_EMAILS; do
                  if [ "$email" = "$declared" ]; then
                    keep=1
                    break
                  fi
                done

                if [ "$keep" -eq 0 ]; then
                  id="$(printf '%s' "$user" | jq -r '.id')"
                  echo "Removing undeclared Immich user: $email"
                  api_delete_json "/api/admin/users/$id" '{"force":false}' "$token" >/dev/null
                fi
              done
            }

            ${passfileLines}

            wait_for_server

            if ! has_any_user; then
              bootstrap_first_admin
            fi

            ACTING_EMAIL=""
            ACTING_TOKEN=""

            if ! try_declared_admin_logins; then
              recover_admin_token
            fi

            [ -n "$ACTING_TOKEN" ] || {
              echo "Unable to obtain an Immich admin token for user reconciliation." >&2
              exit 1
            }

            ${ensureLines}

            if [ "$PRUNE" = "1" ]; then
              PRUNE_TOKEN="$ACTING_TOKEN"
              if try_declared_admin_logins; then
                PRUNE_TOKEN="$ACTING_TOKEN"
              fi
              prune_undeclared_users "$PRUNE_TOKEN"
            fi
          '';

        restartTriggers = [
          (builtins.toJSON sanitizedUsersForRestart)
        ];
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "immich";
        serviceDescription = "Immich";
      }
    ))
  ]);
}
