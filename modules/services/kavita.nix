{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.kavita;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;

  hasValue = value: value != null && value != "";
  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady = hasValue cfg.listenAddress && cfg.port != null;
  effectiveTokenKeyFile =
    if cfg.tokenKeyFile != null then cfg.tokenKeyFile else "${cfg.dataDir}/config/token-key";
  tokenKeyDir = dirOf effectiveTokenKeyFile;

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

  adminUsers = lib.filterAttrs (_: u: u.admin) cfg.users;
  bootstrapAdminName = if adminUsers == { } then null else builtins.head (builtins.attrNames adminUsers);
  reconcileEnabled = cfg.users != { };

  # JSON manifest embedded in the script; sops secret paths resolved at eval time.
  userManifestJson = lib.optionalString reconcileEnabled (
    builtins.toJSON (
      lib.mapAttrs (_: userCfg: {
        inherit (userCfg) admin;
        email = if userCfg.email != null then userCfg.email else "";
        passfile = config.sops.secrets.${userCfg.passwordSecret}.path;
      }) cfg.users
    )
  );
in
{
  options.alanix.kavita = {
    enable = lib.mkEnableOption "Kavita (Alanix)";

    package = lib.mkPackageOption pkgs "kavita" { };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Bind address for Kavita.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port for Kavita.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kavita";
      description = "Kavita data/state directory.";
    };

    tokenKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File containing Kavita's TokenKey. When unset, Alanix generates one
        at dataDir/config/token-key and keeps it with the clustered state.
      '';
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra groups granted to the Kavita service user so it can read media files.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra Kavita appsettings.json options merged with Port and IpAddresses.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          admin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this user has Kavita admin privileges.";
          };

          email = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Email address for this user. Required for all users except the
              bootstrap admin (the first declared admin), because Kavita's
              invite flow uses email to create accounts.
            '';
          };

          passwordSecret = lib.mkOption {
            type = lib.types.str;
            description = "Name of a sops secret containing the user's plaintext password.";
          };
        };
      }));
      default = { };
      description = ''
        Declarative Kavita users. Passwords are read from sops secrets and
        synced on every service start.

        The first declared admin user bootstraps the root account on first boot
        via /api/Account/register. All other users are created through Kavita's
        invite flow (/api/Account/invite + /api/Account/confirm-email) and
        require an email address. Existing users have their passwords reset via
        /api/Account/reset-password on each reconcile run.
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
      description = "Filesystem directories made available to Kavita.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Kavita through alanix.cluster";

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
      serviceName = "kavita";
      serviceDescription = "Kavita";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.kavita.listenAddress must be set when alanix.kavita.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.kavita.port must be set when alanix.kavita.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.kavita.dataDir must be an absolute path.";
          }
          {
            assertion = lib.hasPrefix "/" effectiveTokenKeyFile;
            message = "alanix.kavita.tokenKeyFile must be an absolute path when set.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.kavita.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.kavita.cluster.enable requires alanix.kavita.backupDir to be set.";
          }
          {
            assertion = cfg.users == { } || adminUsers != { };
            message = "alanix.kavita.users must include at least one admin user when non-empty.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.kavita.expose";
        }
        ++ lib.flatten (
          lib.mapAttrsToList
            (folderName: folderCfg: [
              {
                assertion = lib.hasPrefix "/" folderCfg.path;
                message = "alanix.kavita.mediaFolders.${folderName}.path must be an absolute path.";
              }
            ])
            cfg.mediaFolders
        )
        ++ lib.flatten (
          lib.mapAttrsToList
            (uname: userCfg: [
              {
                assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
                message = "alanix.kavita.users.${uname}.passwordSecret '${userCfg.passwordSecret}' must be declared as a sops secret.";
              }
              {
                assertion = uname == bootstrapAdminName || userCfg.email != null;
                message = "alanix.kavita.users.${uname}: email is required for non-bootstrap users (Kavita's invite flow requires it).";
              }
            ])
            cfg.users
        );

      services.kavita = lib.mkIf baseConfigReady {
        enable = true;
        package = cfg.package;
        dataDir = cfg.dataDir;
        tokenKeyFile = effectiveTokenKeyFile;
        settings = cfg.settings // {
          Port = cfg.port;
          IpAddresses = cfg.listenAddress;
        };
      };

      users.users.${config.services.kavita.user}.extraGroups = cfg.extraGroups;

      system.activationScripts.alanixKavitaTokenKey = lib.mkIf baseConfigReady {
        deps = [ "users" ];
        text = ''
          ${pkgs.coreutils}/bin/install -d -m 0750 -o ${config.services.kavita.user} -g ${config.services.kavita.user} ${lib.escapeShellArg tokenKeyDir}
          if [ ! -s ${lib.escapeShellArg effectiveTokenKeyFile} ]; then
            ${pkgs.coreutils}/bin/head -c 64 /dev/urandom | ${pkgs.coreutils}/bin/base64 --wrap=0 > ${lib.escapeShellArg effectiveTokenKeyFile}.tmp
            ${pkgs.coreutils}/bin/chown ${config.services.kavita.user}:${config.services.kavita.user} ${lib.escapeShellArg effectiveTokenKeyFile}.tmp
            ${pkgs.coreutils}/bin/chmod 0600 ${lib.escapeShellArg effectiveTokenKeyFile}.tmp
            ${pkgs.coreutils}/bin/mv ${lib.escapeShellArg effectiveTokenKeyFile}.tmp ${lib.escapeShellArg effectiveTokenKeyFile}
          fi
        '';
      };

      systemd.tmpfiles.rules = lib.mkIf baseConfigReady mediaTmpfilesRules;

      systemd.services.kavita-reconcile-users =
        lib.mkIf (reconcileEnabled && baseConfigReady) {
          description = "Reconcile Kavita users";
          after = [ "kavita.service" "sops-nix.service" ];
          wants = [ "kavita.service" "sops-nix.service" ];
          partOf = [ "kavita.service" ];
          wantedBy = [ "kavita.service" ];

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
            USERS_JSON=${lib.escapeShellArg userManifestJson}

            RESPONSE_STATUS=""
            RESPONSE_BODY=""
            LOGIN_TOKEN=""

            wait_for_server() {
              local attempts=120
              while [ "$attempts" -gt 0 ]; do
                local status
                status=$(curl -so /dev/null -w "%{http_code}" "$BASE_URL/api/Admin/exists" 2>/dev/null || true)
                if [ "$status" = "200" ]; then return 0; fi
                sleep 1
                attempts=$((attempts - 1))
              done
              echo "Timed out waiting for Kavita to become ready." >&2
              return 1
            }

            http_json() {
              local method="$1"
              local path="$2"
              local payload="''${3:-}"
              local token="''${4:-}"
              local body_file curl_args

              body_file="$(mktemp)"
              curl_args=(
                -sS -o "$body_file" -w "%{http_code}"
                -X "$method"
                "$BASE_URL$path"
                -H "Content-Type: application/json"
              )
              [ -n "$token" ] && curl_args+=(-H "Authorization: Bearer $token")
              [ -n "$payload" ] && curl_args+=(--data "$payload")

              RESPONSE_STATUS="$(curl "''${curl_args[@]}" || true)"
              RESPONSE_BODY="$(cat "$body_file")"
              rm -f "$body_file"
            }

            is_success() { [ "$1" = "200" ] || [ "$1" = "201" ] || [ "$1" = "204" ]; }

            do_login() {
              local uname="$1" pass="$2"
              local payload
              payload=$(jq -cn --arg u "$uname" --arg p "$pass" '{username:$u,password:$p}')
              http_json POST "/api/Account/login" "$payload"
              if is_success "$RESPONSE_STATUS"; then
                LOGIN_TOKEN=$(printf '%s' "$RESPONSE_BODY" | jq -r '.token // empty')
                [ -n "$LOGIN_TOKEN" ]
              else
                return 1
              fi
            }

            bootstrap_or_login() {
              local admin_exists passfile pass

              admin_exists=$(curl -sf "$BASE_URL/api/Admin/exists" | jq -r '.')
              passfile=$(printf '%s' "$USERS_JSON" | jq -r --arg u "$ADMIN_USER" '.[$u].passfile')
              pass=$(tr -d '\r\n' < "$passfile")

              if [ "$admin_exists" = "false" ]; then
                echo "Bootstrapping Kavita admin: $ADMIN_USER"
                local email payload
                email=$(printf '%s' "$USERS_JSON" | jq -r --arg u "$ADMIN_USER" '.[$u].email')
                payload=$(jq -cn \
                  --arg username "$ADMIN_USER" \
                  --arg password "$pass" \
                  --arg email "$email" \
                  '{username:$username,password:$password} + (if $email != "" then {email:$email} else {} end)')
                http_json POST "/api/Account/register" "$payload"
                if ! is_success "$RESPONSE_STATUS"; then
                  echo "Failed to bootstrap admin (HTTP $RESPONSE_STATUS): $RESPONSE_BODY" >&2
                  return 1
                fi
                LOGIN_TOKEN=$(printf '%s' "$RESPONSE_BODY" | jq -r '.token // empty')
                echo "Admin bootstrapped."
              else
                echo "Logging in as admin: $ADMIN_USER"
                if ! do_login "$ADMIN_USER" "$pass"; then
                  echo "Admin login failed (HTTP $RESPONSE_STATUS): $RESPONSE_BODY" >&2
                  return 1
                fi
              fi
            }

            get_existing_usernames() {
              curl -sf \
                -H "Authorization: Bearer $LOGIN_TOKEN" \
                "$BASE_URL/api/Users?includePending=true" \
              | jq -r '.[].username'
            }

            invite_and_confirm() {
              local uname="$1" email="$2" pass="$3" is_admin="$4"
              local roles="[]"
              [ "$is_admin" = "true" ] && roles='["Admin"]'

              local invite_payload emailLink inv_token confirm_payload
              invite_payload=$(jq -cn --arg e "$email" --argjson r "$roles" '{email:$e,roles:$r}')
              http_json POST "/api/Account/invite" "$invite_payload" "$LOGIN_TOKEN"
              if ! is_success "$RESPONSE_STATUS"; then
                echo "Invite failed for $uname (HTTP $RESPONSE_STATUS): $RESPONSE_BODY" >&2
                return 1
              fi

              emailLink=$(printf '%s' "$RESPONSE_BODY" | jq -r '.emailLink // empty')
              if [ -z "$emailLink" ]; then
                echo "No emailLink in invite response for $uname: $RESPONSE_BODY" >&2
                return 1
              fi

              # Extract the token query parameter from the invite URL
              inv_token=$(printf '%s' "$emailLink" | sed 's/.*[?&]token=\([^&]*\).*/\1/')
              if [ -z "$inv_token" ] || [ "$inv_token" = "$emailLink" ]; then
                echo "Could not extract token from invite link for $uname: $emailLink" >&2
                return 1
              fi

              confirm_payload=$(jq -cn \
                --arg email "$email" \
                --arg password "$pass" \
                --arg token "$inv_token" \
                --arg username "$uname" \
                '{email:$email,password:$password,token:$token,username:$username}')
              http_json POST "/api/Account/confirm-email" "$confirm_payload"
              if ! is_success "$RESPONSE_STATUS"; then
                echo "Confirm-email failed for $uname (HTTP $RESPONSE_STATUS): $RESPONSE_BODY" >&2
                return 1
              fi

              echo "Created user: $uname"
            }

            reset_password() {
              local uname="$1" pass="$2"
              local payload
              payload=$(jq -cn --arg u "$uname" --arg p "$pass" '{userName:$u,password:$p}')
              http_json POST "/api/Account/reset-password" "$payload" "$LOGIN_TOKEN"
              if ! is_success "$RESPONSE_STATUS"; then
                echo "Password reset failed for $uname (HTTP $RESPONSE_STATUS): $RESPONSE_BODY" >&2
                return 1
              fi
              echo "Password synced: $uname"
            }

            main() {
              wait_for_server
              bootstrap_or_login

              local existing_users
              existing_users=$(get_existing_usernames)

              printf '%s' "$USERS_JSON" \
              | jq -r 'to_entries[] | "\(.key)\t\(.value.admin)\t\(.value.email)\t\(.value.passfile)"' \
              | while IFS=$'\t' read -r uname is_admin email passfile; do
                local pass
                pass=$(tr -d '\r\n' < "$passfile")
                if printf '%s\n' "$existing_users" | grep -qxF "$uname"; then
                  reset_password "$uname" "$pass"
                else
                  invite_and_confirm "$uname" "$email" "$pass" "$is_admin"
                fi
              done

              echo "Kavita user reconciliation complete."
            }

            main
          '';
        };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "kavita";
        serviceDescription = "Kavita";
      }
    ))
  ]);
}
