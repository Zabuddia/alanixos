{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.invidious;
  serviceAccess = import ./_service-access.nix { inherit lib; };

  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  torSecretKeyPath =
    if cfg.torAccess.secretKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.torAccess.secretKeySecret}.path;
  dbPasswordFile =
    if cfg.database.passwordSecret == null then
      null
    else
      config.sops.secrets.${cfg.database.passwordSecret}.path;
  hmacKeyFile =
    if cfg.hmacKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.hmacKeySecret}.path;
  anySopsUserPassword = lib.any (u: u.passwordSecret != null) (lib.attrValues cfg.users);
  userPasswordSecretNames =
    lib.unique (lib.filter (x: x != null) (map (u: u.passwordSecret) (lib.attrValues cfg.users)));
in
{
  options.alanix.invidious = {
    enable = lib.mkEnableOption "Invidious (Alanix)";

    active = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this node actively runs the Invidious service.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
    };

    inherit (serviceAccess.mkBackendFirewallOptions {
      serviceTitle = "Invidious";
      defaultOpenFirewall = false;
    })
      openFirewall
      firewallInterfaces;

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/invidious";
      description = "Invidious state directory (must be under /var/lib).";
    };

    uid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned UID for the invidious system user. Set with gid for multi-node consistency.";
    };

    gid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned GID for the invidious system group. Set with uid for multi-node consistency.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Additional Invidious settings merged into services.invidious.settings.";
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to create and use a local PostgreSQL database.";
      };

      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Database host. null means local unix socket.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
      };

      passwordSecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional sops secret containing the database password (required for non-local DB host).";
      };
    };

    hmacKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional sops secret containing Invidious hmac_key content.";
    };

    sigHelper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable inv-sig-helper for improved playback compatibility.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:2999";
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          password = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Plaintext password (simple, not recommended).";
          };

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to file containing plaintext password.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Name of sops secret containing plaintext password.";
          };
        };
      }));
      default = {};
      description = ''
        Declarative Invidious users. Attribute names are the login IDs used by Invidious
        (its "email" field), for example `buddia` or `buddia@example.com`.
      '';
    };

    wanAccess = serviceAccess.mkWanAccessOptions { serviceTitle = "Invidious"; };

    wireguardAccess = serviceAccess.mkWireguardAccessOptions {
      serviceTitle = "Invidious";
      defaultPort = 8092;
      defaultInterface = "wg0";
    };

    torAccess = serviceAccess.mkTorAccessOptions {
      serviceTitle = "Invidious";
      defaultServiceName = "invidious";
      defaultHttpLocalPort = 18300;
      defaultHttpsLocalPort = 18743;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      (lib.flatten (lib.mapAttrsToList (uname: u:
        let
          chosen = lib.filter (x: x) [
            (u.password != null)
            (u.passwordFile != null)
            (u.passwordSecret != null)
          ];
        in [
          {
            assertion = (builtins.length chosen) == 1;
            message = "alanix.invidious.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          }
          {
            assertion = uname != "";
            message = "alanix.invidious.users keys must be non-empty.";
          }
          {
            assertion = uname == lib.toLower uname;
            message = "alanix.invidious.users.${uname}: user IDs must be lowercase because Invidious lowercases login input.";
          }
        ]
      ) cfg.users))
      ++ [
      {
        assertion = (cfg.uid == null) == (cfg.gid == null);
        message = "alanix.invidious.uid and alanix.invidious.gid must either both be set or both be null.";
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir;
        message = "alanix.invidious.stateDir must be under /var/lib/ so systemd StateDirectory protections keep working.";
      }
      {
        assertion = !(cfg.database.host != null && cfg.database.passwordSecret == null);
        message = "alanix.invidious.database.passwordSecret must be set when alanix.invidious.database.host is non-null.";
      }
      {
        assertion = !(cfg.database.passwordSecret != null && !hasSopsSecrets);
        message = "alanix.invidious.database.passwordSecret requires sops-nix configuration.";
      }
      {
        assertion = !(cfg.hmacKeySecret != null && !hasSopsSecrets);
        message = "alanix.invidious.hmacKeySecret requires sops-nix configuration.";
      }
      {
        assertion = !(anySopsUserPassword && !hasSopsSecrets);
        message = "alanix.invidious.users.*.passwordSecret requires sops-nix configuration.";
      }
    ]
    ++ serviceAccess.mkAccessAssertions {
      inherit cfg hasSopsSecrets;
      modulePathPrefix = "alanix.invidious";
    };

    networking.firewall = serviceAccess.mkAccessFirewallConfig { inherit cfg; };

    sops.secrets = lib.mkMerge [
      (lib.mkIf (hasSopsSecrets && cfg.database.passwordSecret != null) {
        "${cfg.database.passwordSecret}" = {
          restartUnits = [ "invidious.service" ];
        };
      })
      (lib.mkIf (hasSopsSecrets && cfg.hmacKeySecret != null) {
        "${cfg.hmacKeySecret}" = {
          restartUnits = [ "invidious.service" ];
        };
      })
      (lib.mkIf (hasSopsSecrets && userPasswordSecretNames != []) (
        builtins.listToAttrs (map (secretName: {
          name = secretName;
          value.restartUnits = [ "invidious-reconcile-users.service" ];
        }) userPasswordSecretNames)
      ))
    ];

    services.invidious = {
      enable = true;
      address = cfg.listenAddress;
      port = cfg.port;
      nginx.enable = false;
      domain = if cfg.wanAccess.enable then cfg.wanAccess.domain else null;
      settings = cfg.settings;
      hmacKeyFile = hmacKeyFile;

      database = {
        createLocally = cfg.database.createLocally;
        host = cfg.database.host;
        port = cfg.database.port;
        passwordFile = dbPasswordFile;
      };

      sig-helper = {
        enable = cfg.sigHelper.enable;
        listenAddress = cfg.sigHelper.listenAddress;
      };
    };

    # Role controller starts/stops services declaratively on active node.
    systemd.services.invidious.wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
    systemd.services.invidious.restartTriggers = [
      (builtins.toJSON cfg.users)
    ];

    # Keep postgres stopped on standby when this service manages local DB.
    systemd.services.postgresql.wantedBy =
      lib.mkIf (!cfg.active && cfg.database.createLocally) (lib.mkForce []);

    systemd.services.invidious.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce "invidious";
      Group = lib.mkForce "invidious";
      StateDirectory = lib.mkForce (lib.removePrefix "/var/lib/" cfg.stateDir);
    };

    users.groups.invidious = lib.mkMerge [
      {}
      (lib.mkIf (cfg.gid != null) { gid = cfg.gid; })
    ];
    users.users.invidious = {
      isSystemUser = true;
      group = "invidious";
      home = cfg.stateDir;
      createHome = true;
    } // lib.optionalAttrs (cfg.uid != null) {
      uid = cfg.uid;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 invidious invidious - -"
    ];

    systemd.services.invidious-reconcile-users = lib.mkIf (cfg.users != {}) {
      description = "Reconcile Invidious users (create/update declared users)";
      wantedBy = [ "invidious.service" ];
      after = [ "invidious.service" ] ++ lib.optional anySopsUserPassword "sops-install-secrets.service";
      wants = lib.optional anySopsUserPassword "sops-install-secrets.service";
      partOf = [ "invidious.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };

      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.util-linux
        pkgs.whois
        pkgs.postgresql
      ];

      script =
        let
          dbName = config.services.invidious.settings.db.dbname;
          dbUser = config.services.invidious.settings.db.user;

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
                    pwFile = "/run/invidious-reconcile-users/" + safeName + ".pw";
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
                    pwFile = "/run/invidious-reconcile-users/" + safeName + ".pw";
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
              (lib.mapAttrsToList (uname: _u:
                let
                  var = "PASSFILE_" + lib.replaceStrings [ "/" "-" "." "@" " " ] [ "_" "_" "_" "_" "_" ] uname;
                in
                ''
                  ensure_user ${lib.escapeShellArg uname} "${"$"}${var}"
                ''
              ) cfg.users);
        in
        ''
          set -euo pipefail

          DB_NAME=${lib.escapeShellArg dbName}
          DB_USER=${lib.escapeShellArg dbUser}
          DB_HOST=${lib.escapeShellArg (if cfg.database.host == null then "" else cfg.database.host)}
          DB_PORT=${lib.escapeShellArg (toString cfg.database.port)}
          DB_PASSWORD_FILE=${lib.escapeShellArg (if dbPasswordFile == null then "" else dbPasswordFile)}

          mkdir -p /run/invidious-reconcile-users
          chmod 0700 /run/invidious-reconcile-users

          ${passfileLines}
          ${plainWriteLines}

          psql_exec() {
            if [ -z "$DB_HOST" ]; then
              runuser -u postgres -- \
                psql --set=ON_ERROR_STOP=1 --no-password --quiet --tuples-only --no-align \
                --dbname "$DB_NAME" "$@"
            else
              export PGPASSWORD
              PGPASSWORD="$(tr -d '\r\n' < "$DB_PASSWORD_FILE")"
              psql --set=ON_ERROR_STOP=1 --no-password --quiet --tuples-only --no-align \
                --host "$DB_HOST" \
                --port "$DB_PORT" \
                --username "$DB_USER" \
                --dbname "$DB_NAME" "$@"
            fi
          }

          # Ensure users table exists and migrations have been applied.
          psql_exec -c "SELECT 1 FROM users LIMIT 1;" >/dev/null

          make_token() {
            head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
          }

          ensure_user() {
            local user_id="$1"
            local passfile="$2"

            [ -r "$passfile" ] || { echo "Missing password file for $user_id: $passfile" >&2; exit 1; }

            local pw
            pw="$(tr -d '\r\n' < "$passfile")"
            [ -n "$pw" ] || { echo "Empty password for $user_id (from $passfile)" >&2; exit 1; }

            # Invidious truncates signup passwords at 55 bytes before bcrypt.
            if [ "$(printf '%s' "$pw" | wc -c)" -gt 55 ]; then
              pw="$(printf '%s' "$pw" | head -c 55)"
            fi

            local pass_hash token exists
            pass_hash="$(printf '%s\n' "$pw" | mkpasswd -m bcrypt -R 10 -s)"
            token="$(make_token)"

            exists="$(
              psql_exec \
                -v user_id="$user_id" \
                -c "SELECT EXISTS (SELECT 1 FROM users WHERE lower(email) = lower(:'user_id'));" \
                | tr -d '[:space:]'
            )"

            if [ "$exists" = "t" ]; then
              psql_exec \
                -v user_id="$user_id" \
                -v pass_hash="$pass_hash" \
                -v token="$token" \
                -c "
                  UPDATE users
                  SET
                    email = :'user_id',
                    updated = NOW(),
                    notifications = COALESCE(notifications, ARRAY[]::text[]),
                    subscriptions = COALESCE(subscriptions, ARRAY[]::text[]),
                    preferences = COALESCE(preferences, '{}'),
                    password = :'pass_hash',
                    token = COALESCE(token, :'token'),
                    watched = COALESCE(watched, ARRAY[]::text[]),
                    feed_needs_update = COALESCE(feed_needs_update, true)
                  WHERE lower(email) = lower(:'user_id');
                " >/dev/null
              return
            fi

            psql_exec \
              -v user_id="$user_id" \
              -v pass_hash="$pass_hash" \
              -v token="$token" \
              -c "
                INSERT INTO users (
                  updated,
                  notifications,
                  subscriptions,
                  email,
                  preferences,
                  password,
                  token,
                  watched,
                  feed_needs_update
                )
                VALUES (
                  NOW(),
                  ARRAY[]::text[],
                  ARRAY[]::text[],
                  :'user_id',
                  '{}',
                  :'pass_hash',
                  :'token',
                  ARRAY[]::text[],
                  true
                );
              " >/dev/null
          }

          ${ensureLines}
        '';
    };

    services.caddy = serviceAccess.mkAccessCaddyConfig {
      inherit cfg;
      upstreamPort = cfg.port;
    };

    services.tor = serviceAccess.mkTorConfig {
      inherit cfg torSecretKeyPath;
    };
  };
}
