{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.immich;
  serviceAccess = import ./_service-access.nix { inherit lib; };
  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  torSecretKeyPath =
    if cfg.torAccess.secretKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.torAccess.secretKeySecret}.path;
  dbPasswordFile =
    if cfg.database.passwordSecret == null || !hasSopsSecrets then
      null
    else
      config.sops.secrets.${cfg.database.passwordSecret}.path;
  adminPasswordFile =
    if cfg.adminPasswordSecret == null || !hasSopsSecrets then
      null
    else
      config.sops.secrets.${cfg.adminPasswordSecret}.path;
  anySopsUserPassword = lib.any (u: u.passwordSecret != null) (lib.attrValues cfg.users);
  userPasswordSecretNames =
    lib.unique (lib.filter (x: x != null) (map (u: u.passwordSecret) (lib.attrValues cfg.users)));
  needsSopsForUserReconcile = anySopsUserPassword || cfg.adminPasswordSecret != null;
  adminEmailLower = lib.toLower (if cfg.adminEmail == null then "" else cfg.adminEmail);
  adminBootstrapUser =
    lib.findFirst
      (u: lib.toLower u.email == adminEmailLower && u.isAdmin)
      null
      (lib.attrValues cfg.users);
  adminBootstrapName =
    if adminBootstrapUser == null then
      "Admin"
    else
      adminBootstrapUser.displayName;
  dbPasswordEnvFile = "/run/alanix-immich/database.env";
  effectiveDatabaseHost =
    if cfg.database.host == null then
      "/run/postgresql"
    else
      cfg.database.host;
  isTcpDatabaseHost = !(lib.hasPrefix "/" effectiveDatabaseHost);
in
{
  options.alanix.immich = {
    enable = lib.mkEnableOption "Immich (Alanix)";

    active = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this node actively runs the Immich service.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2283;
    };

    inherit (serviceAccess.mkBackendFirewallOptions {
      serviceTitle = "Immich";
      defaultOpenFirewall = false;
    })
      openFirewall
      firewallInterfaces;

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/immich";
      description = "Immich media directory (must be under /var/lib).";
    };

    uid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned UID for the immich system user. Set with gid for multi-node consistency.";
    };

    gid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned GID for the immich system group. Set with uid for multi-node consistency.";
    };

    settings = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = "Immich settings JSON (null leaves settings editable in web UI).";
    };

    environment = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra Immich environment variables.";
    };

    accelerationDevices = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = [ ];
      description = "Acceleration devices passed through to Immich (for example /dev/dri/renderD128).";
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run and initialize local PostgreSQL for Immich.";
      };

      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Database host. null means local unix socket at /run/postgresql.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "immich";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "immich";
      };

      enableVectorChord = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable VectorChord extension for Immich vectors.";
      };

      enableVectors = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable legacy pgvecto.rs extension.";
      };

      passwordSecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional sops secret containing DB_PASSWORD for Immich.";
      };
    };

    redis = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional Redis host override (null uses module default unix socket).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 0;
      };
    };

    machineLearning = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      environment = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
    };

    adminEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Email of an existing Immich admin account used by the reconcile job to manage declarative users.
        Required when alanix.immich.users is non-empty.
      '';
    };

    adminPasswordSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        sops secret containing the password for alanix.immich.adminEmail.
        Required when alanix.immich.users is non-empty.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          email = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Immich user email (login identifier).";
          };

          displayName = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Immich user display name.";
          };

          isAdmin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this user should be an Immich admin.";
          };

          shouldChangePassword = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this user must change password at next login.";
          };

          password = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Plaintext password for this Immich user (simple, not recommended).";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing plaintext password for this Immich user.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "sops secret name containing plaintext password for this Immich user.";
          };
        };
      }));
      default = {};
      description = "Declarative Immich users managed via Immich admin API.";
    };

    wanAccess = serviceAccess.mkWanAccessOptions { serviceTitle = "Immich"; };

    clusterAccess = serviceAccess.mkClusterAccessOptions {
      serviceTitle = "Immich";
      defaultPort = 8093;
      defaultInterface = "tailscale0";
    };

    torAccess = serviceAccess.mkTorAccessOptions {
      serviceTitle = "Immich";
      defaultServiceName = "immich";
      defaultHttpLocalPort = 18283;
      defaultHttpsLocalPort = 18683;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.uid == null) == (cfg.gid == null);
        message = "alanix.immich.uid and alanix.immich.gid must either both be set or both be null.";
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir;
        message = "alanix.immich.stateDir must be under /var/lib/.";
      }
      {
        assertion = !(cfg.database.passwordSecret != null && !hasSopsSecrets);
        message = "alanix.immich.database.passwordSecret requires sops-nix configuration.";
      }
      {
        assertion = !(isTcpDatabaseHost && cfg.database.passwordSecret == null);
        message = "alanix.immich.database.passwordSecret must be set when database.host is TCP (non-socket).";
      }
      {
        assertion = !(cfg.adminPasswordSecret != null && !hasSopsSecrets);
        message = "alanix.immich.adminPasswordSecret requires sops-nix configuration.";
      }
      {
        assertion = !(cfg.users != {} && cfg.adminEmail == null);
        message = "alanix.immich.adminEmail must be set when alanix.immich.users is non-empty.";
      }
      {
        assertion = !(cfg.users != {} && cfg.adminPasswordSecret == null);
        message = "alanix.immich.adminPasswordSecret must be set when alanix.immich.users is non-empty.";
      }
      {
        assertion = !(cfg.users != {} && adminBootstrapUser == null);
        message = "alanix.immich.users must include an admin entry with email == alanix.immich.adminEmail.";
      }
      {
        assertion = !(anySopsUserPassword && !hasSopsSecrets);
        message = "alanix.immich.users.*.passwordSecret requires sops-nix configuration.";
      }
    ]
    ++ lib.concatLists (lib.mapAttrsToList (uname: u: [
      {
        assertion =
          (lib.length (lib.filter (x: x) [
            (u.password != null)
            (u.passwordFile != null)
            (u.passwordSecret != null)
          ])) == 1;
        message = "alanix.immich.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
      }
    ]) cfg.users)
    ++ serviceAccess.mkAccessAssertions {
      inherit cfg hasSopsSecrets;
      modulePathPrefix = "alanix.immich";
    };

    networking.firewall = serviceAccess.mkAccessFirewallConfig { inherit cfg; };

    sops.secrets = lib.mkMerge [
      (lib.mkIf (hasSopsSecrets && cfg.database.passwordSecret != null) {
        "${cfg.database.passwordSecret}" = {
          restartUnits = [
            "immich-db-password-env.service"
            "immich-server.service"
          ];
        };
      })
      (lib.mkIf (hasSopsSecrets && cfg.adminPasswordSecret != null) {
        "${cfg.adminPasswordSecret}" = {
          restartUnits = [ "immich-reconcile-users.service" ];
        };
      })
      (lib.mkIf (hasSopsSecrets && userPasswordSecretNames != []) (
        builtins.listToAttrs (map (secretName: {
          name = secretName;
          value.restartUnits = [ "immich-reconcile-users.service" ];
        }) userPasswordSecretNames)
      ))
    ];

    systemd.services.immich-db-password-env = lib.mkIf (cfg.database.passwordSecret != null) {
      description = "Prepare Immich DB_PASSWORD environment file";
      before = [ "immich-server.service" ];
      requiredBy = [ "immich-server.service" ];
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RuntimeDirectory = "alanix-immich";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -euo pipefail

        SECRET_PATH=${lib.escapeShellArg dbPasswordFile}
        OUT_PATH=${lib.escapeShellArg dbPasswordEnvFile}
        DB_PASSWORD="$(tr -d '\r\n' < "$SECRET_PATH")"

        if [ -z "$DB_PASSWORD" ]; then
          echo "Immich DB password secret is empty: $SECRET_PATH" >&2
          exit 1
        fi

        umask 077
        printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD" > "$OUT_PATH"
      '';
    };

    services.immich = {
      enable = true;
      host = cfg.listenAddress;
      port = cfg.port;
      openFirewall = false;
      mediaLocation = cfg.stateDir;
      settings = cfg.settings;
      environment = cfg.environment;
      accelerationDevices = cfg.accelerationDevices;
      database = {
        enable = cfg.database.createLocally;
        createDB = cfg.database.createLocally;
        host = effectiveDatabaseHost;
        port = cfg.database.port;
        name = cfg.database.name;
        user = cfg.database.user;
        enableVectorChord = cfg.database.enableVectorChord;
        enableVectors = cfg.database.enableVectors;
      };
      redis = {
        enable = cfg.redis.enable;
        port = cfg.redis.port;
      } // lib.optionalAttrs (cfg.redis.host != null) {
        host = cfg.redis.host;
      };
      machine-learning = {
        enable = cfg.machineLearning.enable;
        environment = cfg.machineLearning.environment;
      };
      secretsFile = if cfg.database.passwordSecret == null then null else dbPasswordEnvFile;
    };

    systemd.services.immich-server = {
      wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
      wants = lib.mkIf cfg.machineLearning.enable (lib.mkAfter [ "immich-machine-learning.service" ]);
      restartTriggers = [
        (builtins.toJSON cfg.users)
        (builtins.toJSON cfg.adminEmail)
        (builtins.toJSON cfg.adminPasswordSecret)
      ];
    };

    # Keep local PostgreSQL stopped on standby when this node is not active.
    systemd.services.postgresql.wantedBy =
      lib.mkIf (!cfg.active && cfg.database.createLocally) (lib.mkForce []);

    systemd.services.postgresql-setup.wantedBy =
      lib.mkIf (!cfg.active && cfg.database.createLocally) (lib.mkForce []);

    systemd.services.immich-machine-learning = lib.mkIf cfg.machineLearning.enable {
      partOf = [ "immich-server.service" ];
      wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
    };

    systemd.services.immich-reconcile-users = lib.mkIf (cfg.users != {}) {
      description = "Reconcile Immich users (create/update declared users)";
      wantedBy = [ "immich-server.service" ];
      after = [ "immich-server.service" ] ++ lib.optional needsSopsForUserReconcile "sops-install-secrets.service";
      wants = lib.optional needsSopsForUserReconcile "sops-install-secrets.service";
      partOf = [ "immich-server.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };

      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];

      script =
        let
          passfileLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                let
                  safeName = lib.replaceStrings [ "/" "-" "." "@" " " ] [ "_" "_" "_" "_" "_" ] uname;
                  var = "PASSFILE_" + safeName;
                in
                if u.passwordFile != null then
                  ''${var}=${lib.escapeShellArg (toString u.passwordFile)}''
                else if u.passwordSecret != null then
                  ''${var}=${lib.escapeShellArg config.sops.secrets.${u.passwordSecret}.path}''
                else
                  let
                    pwFile = "/run/immich-reconcile-users/" + safeName + ".pw";
                  in
                  ''${var}=${lib.escapeShellArg pwFile}''
              ) cfg.users);

          plainWriteLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                if u.password == null then
                  ""
                else
                  let
                    safeName = lib.replaceStrings [ "/" "-" "." "@" " " ] [ "_" "_" "_" "_" "_" ] uname;
                    pwFile = "/run/immich-reconcile-users/" + safeName + ".pw";
                  in
                  ''
                    cat > ${lib.escapeShellArg pwFile} <<'EOF'
                    ${u.password}
                    EOF
                    chmod 0600 ${lib.escapeShellArg pwFile}
                  ''
              ) cfg.users);

          ensureLines =
            lib.concatStringsSep "\n"
              (lib.mapAttrsToList (uname: u:
                let
                  safeName = lib.replaceStrings [ "/" "-" "." "@" " " ] [ "_" "_" "_" "_" "_" ] uname;
                  var = "PASSFILE_" + safeName;
                in
                ''
                  ensure_user \
                    ${lib.escapeShellArg u.email} \
                    ${lib.escapeShellArg u.displayName} \
                    ${if u.isAdmin then "true" else "false"} \
                    ${if u.shouldChangePassword then "true" else "false"} \
                    "${"$"}${var}"
                ''
              ) cfg.users);
        in
        ''
          set -euo pipefail

          API_BASE=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}/api"}
          ADMIN_EMAIL=${lib.escapeShellArg cfg.adminEmail}
          ADMIN_NAME=${lib.escapeShellArg adminBootstrapName}
          ADMIN_PASSWORD_FILE=${lib.escapeShellArg adminPasswordFile}

          mkdir -p /run/immich-reconcile-users
          chmod 0700 /run/immich-reconcile-users

          ${passfileLines}
          ${plainWriteLines}

          [ -r "$ADMIN_PASSWORD_FILE" ] || {
            echo "Missing admin password file for Immich reconcile: $ADMIN_PASSWORD_FILE" >&2
            exit 1
          }

          ADMIN_PASSWORD="$(tr -d '\r\n' < "$ADMIN_PASSWORD_FILE")"
          [ -n "$ADMIN_PASSWORD" ] || {
            echo "Immich admin password is empty in $ADMIN_PASSWORD_FILE" >&2
            exit 1
          }

          login_admin() {
            local payload token
            payload="$(jq -cn --arg email "$ADMIN_EMAIL" --arg password "$ADMIN_PASSWORD" '{email:$email,password:$password}')"
            token="$(
              curl -fsS -X POST "$API_BASE/auth/login" \
                -H 'content-type: application/json' \
                --data-raw "$payload" \
              | jq -r '.accessToken // empty'
            )"
            [ -n "$token" ] || return 1
            printf '%s' "$token"
          }

          bootstrap_admin_if_needed() {
            local payload code body_file body_text
            payload="$(
              jq -cn \
                --arg email "$ADMIN_EMAIL" \
                --arg password "$ADMIN_PASSWORD" \
                --arg name "$ADMIN_NAME" \
                '{email:$email,password:$password,name:$name}'
            )"

            body_file="$(mktemp /run/immich-reconcile-users/bootstrap.XXXXXX)"
            code="$(
              curl -sS -o "$body_file" -w '%{http_code}' -X POST "$API_BASE/auth/admin-sign-up" \
                -H 'content-type: application/json' \
                --data-raw "$payload" || true
            )"
            body_text="$(tr -d '\r' < "$body_file" | tr '\n' ' ' | head -c 400)"
            rm -f "$body_file"

            case "$code" in
              200|201)
                echo "immich-reconcile-users: bootstrapped initial admin: $ADMIN_EMAIL" >&2
                return 0
                ;;
              400|409)
                if [ -n "$body_text" ]; then
                  echo "immich-reconcile-users: admin bootstrap not applied (HTTP $code): $body_text" >&2
                else
                  echo "immich-reconcile-users: admin bootstrap not applied (HTTP $code)" >&2
                fi
                return 2
                ;;
              *)
                if [ -n "$body_text" ]; then
                  echo "immich-reconcile-users: admin bootstrap failed (HTTP $code): $body_text" >&2
                else
                  echo "immich-reconcile-users: admin bootstrap failed (HTTP $code)" >&2
                fi
                return 1
                ;;
            esac
          }

          wait_for_api() {
            local i
            for i in $(seq 1 180); do
              if curl -fsS "$API_BASE/server/ping" >/dev/null 2>&1; then
                return 0
              fi
              sleep 1
            done
            echo "immich-reconcile-users: Immich API not ready at $API_BASE/server/ping" >&2
            return 1
          }

          wait_for_api

          TOKEN=""
          signup_attempted=0
          for _ in $(seq 1 120); do
            if TOKEN="$(login_admin 2>/dev/null)"; then
              break
            fi

            if [ "$signup_attempted" -eq 0 ]; then
              if bootstrap_admin_if_needed; then
                signup_attempted=1
              else
                bootstrap_rc=$?
                if [ "$bootstrap_rc" -eq 2 ]; then
                  signup_attempted=1
                fi
              fi
            fi

            sleep 1
          done

          [ -n "$TOKEN" ] || {
            echo "Unable to authenticate to Immich admin API for reconcile" >&2
            exit 1
          }

          fetch_users() {
            curl -fsS \
              -H "authorization: Bearer $TOKEN" \
              "$API_BASE/admin/users"
          }

          users_json="$(fetch_users)"

          ensure_user() {
            local email="$1"
            local display_name="$2"
            local is_admin="$3"
            local should_change_password="$4"
            local passfile="$5"

            [ -r "$passfile" ] || { echo "Missing password file for $email: $passfile" >&2; exit 1; }

            local password email_lc user_id payload
            password="$(tr -d '\r\n' < "$passfile")"
            [ -n "$password" ] || { echo "Empty password for $email (from $passfile)" >&2; exit 1; }

            email_lc="$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')"
            user_id="$(
              printf '%s' "$users_json" \
                | jq -r --arg email "$email_lc" 'map(select((.email | ascii_downcase) == $email)) | .[0].id // empty'
            )"

            payload="$(
              jq -cn \
                --arg email "$email" \
                --arg name "$display_name" \
                --arg password "$password" \
                --argjson isAdmin "$is_admin" \
                --argjson shouldChangePassword "$should_change_password" \
                '{
                  email: $email,
                  name: $name,
                  password: $password,
                  isAdmin: $isAdmin,
                  shouldChangePassword: $shouldChangePassword
                }'
            )"

            if [ -n "$user_id" ]; then
              curl -fsS -X PUT \
                -H "authorization: Bearer $TOKEN" \
                -H 'content-type: application/json' \
                --data-raw "$payload" \
                "$API_BASE/admin/users/$user_id" >/dev/null
            else
              curl -fsS -X POST \
                -H "authorization: Bearer $TOKEN" \
                -H 'content-type: application/json' \
                --data-raw "$payload" \
                "$API_BASE/admin/users" >/dev/null
            fi

            users_json="$(fetch_users)"
          }

          ${ensureLines}
        '';
    };

    users.groups.immich = lib.mkMerge [
      { }
      (lib.mkIf (cfg.gid != null) { gid = cfg.gid; })
    ];
    users.users.immich = lib.mkMerge [
      { }
      (lib.mkIf (cfg.uid != null) { uid = cfg.uid; })
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 immich immich - -"
    ];

    services.caddy = serviceAccess.mkAccessCaddyConfig {
      inherit cfg;
      upstreamPort = cfg.port;
    };

    services.tor = serviceAccess.mkTorConfig {
      inherit cfg torSecretKeyPath;
    };
  };
}
