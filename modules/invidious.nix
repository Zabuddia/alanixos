{ config, lib, pkgs, pkgs-unstable ? pkgs, inputs, ... }:
let
  cfg = config.alanix.invidious;
  serviceAccess = import ./_service-access.nix { inherit lib; };

  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  dbPasswordFile =
    if cfg.database.passwordSecret == null || !hasSopsSecrets then
      null
    else
      config.sops.secrets.${cfg.database.passwordSecret}.path;
  hmacKeyFile =
    if cfg.hmacKeySecret == null || !hasSopsSecrets then
      null
    else
      config.sops.secrets.${cfg.hmacKeySecret}.path;
  hmacKeyJsonFile = "/run/alanix-invidious/hmac-key.json";
  companionSettingsFile = "/run/alanix-invidious/companion-settings.json";
  companionEnvFile = "/run/alanix-invidious/companion.env";
  companionListenMatch = builtins.match "^([^:]+):([0-9]+)$" cfg.companion.listenAddress;
  companionHost =
    if companionListenMatch == null then
      null
    else
      builtins.elemAt companionListenMatch 0;
  companionPort =
    if companionListenMatch == null then
      null
    else
      builtins.elemAt companionListenMatch 1;
  companionPrivateUrl =
    if companionListenMatch == null then
      null
    else
      "http://${cfg.companion.listenAddress}/companion";
  hasLegacyDefaultHome = cfg.settings ? default_home;
  hasLegacyFeedMenu = cfg.settings ? feed_menu;
  hasDefaultUserPreferences = cfg.settings ? default_user_preferences;
  invidiousSettingsBase = builtins.removeAttrs cfg.settings [ "default_home" "feed_menu" ];
  invidiousDefaultUserPreferences =
    (if hasDefaultUserPreferences then cfg.settings.default_user_preferences else {})
    // lib.optionalAttrs hasLegacyDefaultHome { default_home = cfg.settings.default_home; }
    // lib.optionalAttrs hasLegacyFeedMenu { feed_menu = cfg.settings.feed_menu; };
  effectiveInvidiousSettings =
    invidiousSettingsBase
    // lib.optionalAttrs (hasDefaultUserPreferences || hasLegacyDefaultHome || hasLegacyFeedMenu) {
      default_user_preferences = invidiousDefaultUserPreferences;
    };
  invidiousCompanionSource = inputs.invidious-companion-src;
  defaultInvidiousPackage = pkgs-unstable.invidious;
  invidiousCompanionPackage = pkgs.writeShellApplication {
    name = "invidious_companion";
    runtimeInputs = [ pkgs.deno ];
    text = ''
      set -euo pipefail

      cd ${invidiousCompanionSource}
      exec deno run \
        --allow-import=github.com:443,jsr.io:443,cdn.jsdelivr.net:443,esm.sh:443,deno.land:443 \
        --allow-net \
        --allow-env \
        --allow-sys=hostname \
        --allow-read=.,/tmp/invidious-companion.sock,/var/cache/invidious-companion \
        --allow-write=/var/cache/invidious-companion,/tmp/invidious-companion.sock \
        src/main.ts "$@"
    '';
  };
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

    cookieDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional cookie domain for Invidious SID/PREFS cookies.
        Leave null to make cookies host-only so login works consistently across
        multiple entrypoints (for example WAN domain, cluster-private IP, and .onion).
      '';
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

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultInvidiousPackage;
      defaultText = lib.literalExpression "pkgs-unstable.invidious";
      description = "Invidious package to run.";
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

    companion = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Invidious companion service and companion integration.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:2999";
        description = "TCP listen address for the companion endpoint.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = invidiousCompanionPackage;
        defaultText = lib.literalExpression "invidiousCompanionPackage";
        description = "Package providing the `invidious_companion` binary.";
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

    clusterAccess = serviceAccess.mkClusterAccessOptions {
      serviceTitle = "Invidious";
      defaultPort = 8092;
      defaultInterface = "tailscale0";
    };

    torAccess = serviceAccess.mkTorAccessOptions {
      serviceTitle = "Invidious";
      defaultServiceName = "invidious";
      defaultHttpLocalPort = 18300;
      defaultHttpsLocalPort = 18743;
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = lib.optionals (hasLegacyDefaultHome || hasLegacyFeedMenu) [
      "alanix.invidious.settings.default_home/feed_menu are legacy top-level keys; move them under alanix.invidious.settings.default_user_preferences.* (they are auto-migrated for now)."
    ];

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
        assertion = cfg.hmacKeySecret != null;
        message = ''
          alanix.invidious.hmacKeySecret must be set.
          Store the key in sops and set this to that secret path (for example "invidious/hmac-key").
        '';
      }
      {
        assertion = hasSopsSecrets;
        message = "alanix.invidious.hmacKeySecret requires sops-nix configuration.";
      }
      {
        assertion = !(anySopsUserPassword && !hasSopsSecrets);
        message = "alanix.invidious.users.*.passwordSecret requires sops-nix configuration.";
      }
      {
        assertion = !(cfg.companion.enable && companionListenMatch == null);
        message = "alanix.invidious.companion.listenAddress must be in HOST:PORT format (for example 127.0.0.1:2999).";
      }
      {
        assertion = !(cfg.companion.enable && (cfg.settings ? signature_server));
        message = "Do not set alanix.invidious.settings.signature_server when companion is enabled.";
      }
    ]
    ++ serviceAccess.mkAccessAssertions {
      inherit cfg hasSopsSecrets;
      modulePathPrefix = "alanix.invidious";
    };

    sops.secrets = lib.mkMerge [
      (lib.mkIf (hasSopsSecrets && cfg.database.passwordSecret != null) {
        "${cfg.database.passwordSecret}" = {
          restartUnits = [ "invidious.service" ];
        };
      })
      (lib.mkIf (hasSopsSecrets && cfg.hmacKeySecret != null) {
        "${cfg.hmacKeySecret}" = {
          restartUnits =
            [ "invidious.service" ]
            ++ lib.optionals cfg.companion.enable [
              "invidious-companion.service"
              "invidious-companion-config.service"
            ];
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
      package = cfg.package;
      address = cfg.listenAddress;
      port = cfg.port;
      nginx.enable = false;
      domain = cfg.cookieDomain;
      settings = effectiveInvidiousSettings // lib.optionalAttrs cfg.companion.enable {
        invidious_companion = [
          {
            private_url = companionPrivateUrl;
          }
        ];
      };
      extraSettingsFile = lib.mkIf cfg.companion.enable companionSettingsFile;
      hmacKeyFile = hmacKeyJsonFile;

      database = {
        createLocally = cfg.database.createLocally;
        host = cfg.database.host;
        port = cfg.database.port;
        passwordFile = dbPasswordFile;
      };

      sig-helper = {
        enable = false;
        listenAddress = cfg.companion.listenAddress;
      };
    };

    # Node failover controller starts/stops services declaratively on the active node.
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

    systemd.services.invidious-hmac-key-json = {
      description = "Prepare Invidious hmac_key JSON";
      before = [ "invidious.service" ];
      requiredBy = [ "invidious.service" ];
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RuntimeDirectory = "alanix-invidious";
        # invidious service user must traverse this directory to read hmac-key.json
        RuntimeDirectoryMode = "0711";
        RuntimeDirectoryPreserve = "yes";
      };
      path = [
        pkgs.coreutils
        pkgs.jq
      ];
      script = ''
        set -euo pipefail

        HMAC_PATH=${lib.escapeShellArg hmacKeyFile}
        OUT_PATH=${lib.escapeShellArg hmacKeyJsonFile}
        TMP_PATH="$(mktemp /run/alanix-invidious/hmac-key.XXXXXX)"
        HMAC="$(tr -d '\r\n' < "$HMAC_PATH")"

        if [ -z "$HMAC" ]; then
          echo "Invidious hmac key is empty in $HMAC_PATH" >&2
          rm -f "$TMP_PATH"
          exit 1
        fi

        jq -cn --arg hmac_key "$HMAC" '{hmac_key:$hmac_key}' > "$TMP_PATH"
        chown invidious:invidious "$TMP_PATH"
        chmod 0400 "$TMP_PATH"
        mv -f "$TMP_PATH" "$OUT_PATH"
      '';
    };

    systemd.services.invidious-companion-config = lib.mkIf cfg.companion.enable {
      description = "Prepare Invidious companion environment and settings";
      before = [
        "invidious.service"
        "invidious-companion.service"
      ];
      requiredBy = [
        "invidious.service"
        "invidious-companion.service"
      ];
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RuntimeDirectory = "alanix-invidious";
        RuntimeDirectoryMode = "0711";
        RuntimeDirectoryPreserve = "yes";
      };
      path = [
        pkgs.coreutils
        pkgs.jq
      ];
      script = ''
        set -euo pipefail

        HMAC_PATH=${lib.escapeShellArg hmacKeyFile}
        COMPANION_ENV=${lib.escapeShellArg companionEnvFile}
        COMPANION_SETTINGS=${lib.escapeShellArg companionSettingsFile}
        COMPANION_URL=${lib.escapeShellArg companionPrivateUrl}

        HMAC="$(tr -d '\r\n' < "$HMAC_PATH")"
        [ -n "$HMAC" ] || { echo "Invidious hmac key is empty in $HMAC_PATH" >&2; exit 1; }

        # Derive a stable 16-char companion secret from the cluster hmac key.
        COMPANION_KEY="$(printf '%s' "$HMAC" | sha256sum | cut -c1-16)"
        [ "''${#COMPANION_KEY}" -eq 16 ] || { echo "Derived companion key has invalid length" >&2; exit 1; }

        TMP_ENV="$(mktemp /run/alanix-invidious/companion-env.XXXXXX)"
        TMP_SETTINGS="$(mktemp /run/alanix-invidious/companion-settings.XXXXXX)"

        cat > "$TMP_ENV" <<EOF
        HOST=${companionHost}
        PORT=${companionPort}
        SERVER_BASE_PATH=/companion
        SERVER_SECRET_KEY=$COMPANION_KEY
        CACHE_DIRECTORY=/var/cache/invidious-companion
        EOF

        jq -cn \
          --arg private_url "$COMPANION_URL" \
          --arg companion_key "$COMPANION_KEY" \
          '{invidious_companion:[{private_url:$private_url}], invidious_companion_key:$companion_key}' \
          > "$TMP_SETTINGS"

        chown invidious:invidious "$TMP_ENV" "$TMP_SETTINGS"
        chmod 0400 "$TMP_ENV" "$TMP_SETTINGS"
        mv -f "$TMP_ENV" "$COMPANION_ENV"
        mv -f "$TMP_SETTINGS" "$COMPANION_SETTINGS"
      '';
    };

    systemd.services.invidious-companion = lib.mkIf cfg.companion.enable {
      description = "Invidious companion";
      before = [ "invidious.service" ];
      requiredBy = [ "invidious.service" ];
      wants = [
        "network-online.target"
        "invidious-companion-config.service"
      ];
      after = [
        "network-online.target"
        "invidious-companion-config.service"
      ];
      partOf = [ "invidious.service" ];

      serviceConfig = {
        Type = "simple";
        User = "invidious";
        Group = "invidious";
        ExecStart = lib.getExe' cfg.companion.package "invidious_companion";
        EnvironmentFile = companionEnvFile;
        Environment = [ "DENO_DIR=/var/cache/invidious-companion/deno" ];
        TimeoutStartSec = "10min";
        Restart = "always";
        RestartSec = "2s";
        CacheDirectory = "invidious-companion";
        CacheDirectoryMode = "0750";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
      };
    };

    # Ensure legacy helper never starts when this module manages companion mode.
    systemd.services.invidious-sig-helper.enable = lib.mkForce false;

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
      "z ${cfg.stateDir} 0750 invidious invidious - -"
      "z /var/lib/invidious 0750 invidious invidious - -"
      "z /var/lib/invidious/hmac_key 0600 invidious invidious - -"
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
        pkgs.mkpasswd
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
              (lib.mapAttrsToList (uname: u:
                let
                  safeName = lib.replaceStrings [ "/" "-" "." "@" " " ] [ "_" "_" "_" "_" "_" ] uname;
                  var = "PASSFILE_" + safeName;
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

          sql_escape() {
            printf '%s' "$1" | gawk '{ gsub(/\047/, "\047\047"); printf "%s", $0 }'
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
            local user_sql pass_hash_sql token_sql
            user_sql="$(sql_escape "$user_id")"
            pass_hash_sql="$(sql_escape "$pass_hash")"
            token_sql="$(sql_escape "$token")"

            exists="$(
              psql_exec \
                -c "SELECT EXISTS (SELECT 1 FROM users WHERE lower(email) = lower('${"$"}user_sql'));" \
                | tr -d '[:space:]'
            )"

            if [ "$exists" = "t" ]; then
              psql_exec \
                -c "
                  UPDATE users
                  SET
                    email = '${"$"}user_sql',
                    updated = NOW(),
                    notifications = COALESCE(notifications, ARRAY[]::text[]),
                    preferences = COALESCE(preferences, '{}'),
                    password = '${"$"}pass_hash_sql',
                    token = COALESCE(token, '${"$"}token_sql'),
                    watched = COALESCE(watched, ARRAY[]::text[]),
                    feed_needs_update = true
                  WHERE lower(email) = lower('${"$"}user_sql');
                " >/dev/null
              return
            fi

            psql_exec \
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
                  '${"$"}user_sql',
                  '{}',
                  '${"$"}pass_hash_sql',
                  '${"$"}token_sql',
                  ARRAY[]::text[],
                  true
                );
              " >/dev/null
          }

          ${ensureLines}
        '';
    };

  };
}
