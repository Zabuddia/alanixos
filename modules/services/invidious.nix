{ config, lib, pkgs, pkgs-unstable, inputs, ... }:
let
  cfg = config.alanix.invidious;
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

  declaredUsernames = builtins.attrNames cfg.users;
  declaredUsersList = lib.concatStringsSep " " declaredUsernames;

  effectiveDomain = serviceIdentity.advertisedDomain {
    inherit config exposeCfg;
    listenAddress = cfg.listenAddress;
    domainOverride = cfg.domain;
    allowWireguard = false;
    allowListenAddressFallback = false;
  };

  effectiveExternalPort = serviceIdentity.externalPort {
    inherit exposeCfg;
    port = cfg.port;
  };

  effectiveHttpsOnly = serviceIdentity.httpsOnly {
    inherit exposeCfg;
  };

  adminUsers =
    lib.mapAttrsToList
      (name: _: name)
      (lib.filterAttrs (_: userCfg: userCfg.admin) cfg.users);

  companionEndpoint = "http://${cfg.companion.listenAddress}:${toString cfg.companion.port}${cfg.companion.basePath}";

  companionPackage =
    let
      assets = {
        x86_64-linux = {
          url = "https://github.com/iv-org/invidious-companion/releases/download/release-master/invidious_companion-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-zWYcwXFy6Sna65guhzI9Z5PeQZiNSGp1TsQJ/zISMe4=";
        };
        aarch64-linux = {
          url = "https://github.com/iv-org/invidious-companion/releases/download/release-master/invidious_companion-aarch64-unknown-linux-gnu.tar.gz";
          hash = "sha256-8mVTV2grTYj8h4Hh+4GTf4ksABmtH2W1nZ9WFd4o73o=";
        };
      }.${pkgs.stdenv.hostPlatform.system} or (throw "alanix.invidious: unsupported platform for invidious-companion prebuilt package.");
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "invidious-companion";
      version = "release-master";

      src = pkgs.fetchurl assets;

      dontUnpack = true;

      installPhase = ''
        runHook preInstall

        mkdir -p "$out/bin"
        tar -xzf "$src"
        install -m0755 invidious_companion "$out/bin/invidious-companion"

        runHook postInstall
      '';

      meta = with lib; {
        description = "Companion for Invidious that handles YouTube stream retrieval";
        homepage = "https://github.com/iv-org/invidious-companion";
        license = licenses.agpl3Plus;
        mainProgram = "invidious-companion";
        platforms = builtins.attrNames {
          x86_64-linux = null;
          aarch64-linux = null;
        };
      };
    };

  defaultSettings = {
    check_tables = true;
    login_enabled = true;
    registration_enabled = !cfg.disableRegistration;
    captcha_enabled = cfg.captchaEnabled;
    host_binding = cfg.listenAddress;
    external_port = effectiveExternalPort;
    https_only = effectiveHttpsOnly;
    admins = adminUsers;
  };

  sanitizedUsersForRestart = passwordUsers.sanitizeForRestart {
    users = cfg.users;
    inheritFields = [ "admin" "passwordSecret" ];
  };
in
{
  disabledModules = [ "services/web-apps/invidious.nix" ];

  imports = [
    (inputs.nixpkgs-unstable + "/nixos/modules/services/web-apps/invidious.nix")
  ];

  options.alanix.invidious = {
    enable = lib.mkEnableOption "Invidious (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
    };

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional public domain or address advertised by Invidious.";
    };

    disableRegistration = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    captchaEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Invidious cluster backup staging directory.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Invidious through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "15m";
      };
    };

    pruneUndeclaredUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete Invidious users that are not present in alanix.invidious.users.";
    };

    hmacKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional sops secret name containing the Invidious hmac_key.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra services.invidious.settings merged on top of the Alanix defaults.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = passwordUsers.mkOptions {
          extraOptions = {
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        };
      }));
      default = { };
      description = "Declarative Invidious users keyed by their login identifier.";
    };

    companion = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8282;
      };

      basePath = lib.mkOption {
        type = lib.types.str;
        default = "/companion";
      };

      publicUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };

      secretKeySecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of the sops secret containing the 16-character alphanumeric companion secret key.";
      };

      verifyRequests = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      encryptQueryParams = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "invidious";
      serviceDescription = "Invidious";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = cfg.users != { };
            message = "alanix.invidious: users must not be empty when enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.invidious.listenAddress must be set when alanix.invidious.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.invidious.port must be set when alanix.invidious.enable = true.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.invidious.backupDir must be an absolute path when set.";
          }
          {
            assertion = !cfg.companion.enable || cfg.companion.secretKeySecret != null;
            message = "alanix.invidious.companion.secretKeySecret must be set when the companion is enabled.";
          }
          {
            assertion = cfg.hmacKeySecret == null || lib.hasAttrByPath [ "sops" "secrets" cfg.hmacKeySecret ] config;
            message = "alanix.invidious.hmacKeySecret must reference a declared sops secret.";
          }
          {
            assertion = !cfg.companion.enable || lib.hasAttrByPath [ "sops" "secrets" cfg.companion.secretKeySecret ] config;
            message = "alanix.invidious.companion.secretKeySecret must reference a declared sops secret.";
          }
          {
            assertion = config.services.invidious.database.createLocally;
            message = "alanix.invidious declarative users currently support only a locally managed PostgreSQL database.";
          }
          {
            assertion = config.services.invidious.database.host == null;
            message = "alanix.invidious declarative users currently require services.invidious.database.host = null.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.invidious.cluster.enable requires alanix.invidious.backupDir to be set.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.invidious.expose";
        }
        ++ passwordUsers.mkAssertions {
          inherit config;
          users = cfg.users;
          usernamePattern = "^[a-z0-9._@+-]+$";
          usernameMessage = uname: "alanix.invidious.users.${uname}: user IDs may contain only lowercase letters, digits, dot, underscore, at-sign, plus, and hyphen.";
          passwordSourceMessage = uname: "alanix.invidious.users.${uname}: set exactly one of password, passwordFile, or passwordSecret.";
          passwordSecretMessage = uname: "alanix.invidious.users.${uname}.passwordSecret must reference a declared sops secret.";
        };

      users.groups.invidious = { };
      users.users.invidious = {
        isSystemUser = true;
        group = "invidious";
        home = "/var/lib/invidious";
        createHome = true;
      };

      sops.templates."alanix-invidious-extra-settings" = lib.mkIf (cfg.companion.enable || cfg.hmacKeySecret != null) {
        content =
          builtins.toJSON (
            {
              invidious_companion = [
                ({
                  private_url = companionEndpoint;
                }
                // lib.optionalAttrs (cfg.companion.publicUrl != null) {
                  public_url = cfg.companion.publicUrl;
                })
              ];
              invidious_companion_key = config.sops.placeholder.${cfg.companion.secretKeySecret};
            }
            // lib.optionalAttrs (cfg.hmacKeySecret != null) {
              hmac_key = config.sops.placeholder.${cfg.hmacKeySecret};
            }
          );
        owner = "invidious";
        group = "invidious";
        mode = "0400";
      };

      services.invidious = lib.mkIf baseConfigReady {
        enable = true;
        package = pkgs-unstable.invidious;
        address = cfg.listenAddress;
        port = cfg.port;
        domain =
          lib.mkIf
            (hasValue cfg.domain || (exposeCfg.wan.enable && hasValue exposeCfg.wan.domain))
            effectiveDomain;
        serviceScale = 1;
        database.createLocally = true;
        database.host = null;
        extraSettingsFile =
          lib.mkIf
            (cfg.companion.enable || cfg.hmacKeySecret != null)
            config.sops.templates."alanix-invidious-extra-settings".path;
        settings = lib.recursiveUpdate defaultSettings cfg.settings;
        http3-ytproxy.package = pkgs-unstable.http3-ytproxy;
        sig-helper.enable = lib.mkForce false;
      };

      systemd.services.invidious.serviceConfig.DynamicUser = lib.mkForce false;
      systemd.services.invidious.serviceConfig.User = lib.mkForce "invidious";
      systemd.services.invidious.serviceConfig.Group = lib.mkForce "invidious";
      systemd.services.invidious.unitConfig.StartLimitIntervalSec = 0;
      systemd.services.invidious.after = lib.mkIf cfg.companion.enable [ "invidious-companion.service" ];
      systemd.services.invidious.wants = lib.mkIf cfg.companion.enable [ "invidious-companion.service" ];

      systemd.tmpfiles.rules = [
        "d /var/lib/invidious 0750 invidious invidious - -"
      ];

      systemd.services.invidious-companion = lib.mkIf cfg.companion.enable {
        description = "Invidious companion";
        wantedBy = [ "multi-user.target" ];
        before = [ "invidious.service" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        serviceConfig = {
          Type = "simple";
          User = "invidious";
          Group = "invidious";
          Restart = "always";
          RestartSec = "2s";
          LoadCredential = [ "server_secret_key:${config.sops.secrets.${cfg.companion.secretKeySecret}.path}" ];
          StateDirectory = "invidious-companion";
          StateDirectoryMode = "0750";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
        };

        path = [ pkgs.coreutils ];

        script = ''
          set -euo pipefail

          export SERVER_SECRET_KEY="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/server_secret_key")"
          export HOST=${lib.escapeShellArg cfg.companion.listenAddress}
          export PORT=${lib.escapeShellArg (toString cfg.companion.port)}
          export SERVER_BASE_PATH=${lib.escapeShellArg cfg.companion.basePath}
          export SERVER_VERIFY_REQUESTS=${if cfg.companion.verifyRequests then "true" else "false"}
          export SERVER_ENCRYPT_QUERY_PARAMS=${if cfg.companion.encryptQueryParams then "true" else "false"}
          export CACHE_DIRECTORY=/var/lib/invidious-companion

          exec ${lib.getExe companionPackage}
        '';
      };

      systemd.services.invidious-reconcile-users = lib.mkIf (cfg.users != { } && baseConfigReady) {
        description = "Reconcile Invidious users (create declared; optionally prune undeclared)";
        after = [ "invidious.service" "postgresql.service" "sops-nix.service" ];
        wants = [ "invidious.service" "postgresql.service" "sops-nix.service" ];
        partOf = [ "invidious.service" ];
        wantedBy = [ "invidious.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "invidious";
          Group = "invidious";
          UMask = "0077";
          WorkingDirectory = "/var/lib/invidious";
          RuntimeDirectory = "alanix-invidious";
          RuntimeDirectoryMode = "0700";
        };

        environment = {
          PGHOST = "/run/postgresql";
          PGUSER = config.services.invidious.settings.db.user;
          PGDATABASE = config.services.invidious.settings.db.dbname;
        };

        path = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.mkpasswd
          pkgs.openssl
          config.services.postgresql.package
        ];

        script =
          let
            passfileLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: u:
                  let
                    var = "PASSFILE_" + lib.replaceStrings [ "-" "." "@" "+" ] [ "_" "_" "_" "_" ] uname;
                    runtimePassfile = "$RUNTIME_DIRECTORY/${lib.replaceStrings [ "-" "." "@" "+" ] [ "_" "_" "_" "_" ] uname}.pass";
                  in
                  if u.passwordFile != null then
                    ''${var}=${lib.escapeShellArg (toString u.passwordFile)}''
                  else if u.passwordSecret != null then
                    ''${var}=${lib.escapeShellArg config.sops.secrets.${u.passwordSecret}.path}''
                  else
                    ''${var}=${lib.escapeShellArg runtimePassfile}; ensure_runtime_passfile "${"$"}${var}" ${lib.escapeShellArg u.password}''
                ) cfg.users);

            ensureLines =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList (uname: _:
                  let
                    var = "PASSFILE_" + lib.replaceStrings [ "-" "." "@" "+" ] [ "_" "_" "_" "_" ] uname;
                  in
                  ''ensure_user ${lib.escapeShellArg uname} "${"$"}${var}"''
                ) cfg.users);
          in
          ''
            set -euo pipefail

            DECLARED=${lib.escapeShellArg declaredUsersList}
            PRUNE=${if cfg.pruneUndeclaredUsers then "1" else "0"}

            run_sql() {
              psql -v ON_ERROR_STOP=1 -qAt -c "$1"
            }

            relation_exists() {
              local relation="$1"
              [ "$(run_sql "SELECT to_regclass('public.' || '$relation') IS NOT NULL;")" = "t" ]
            }

            wait_for_users_table() {
              local attempts=60

              while [ "$attempts" -gt 0 ]; do
                if relation_exists "users"; then
                  return 0
                fi

                sleep 1
                attempts=$((attempts - 1))
              done

              echo "Timed out waiting for Invidious to create the users table." >&2
              return 1
            }

            ensure_runtime_passfile() {
              local path="$1"
              local value="$2"
              umask 077
              printf '%s' "$value" > "$path"
            }

            sql_quote() {
              printf '%s' "$1" | awk '{ gsub(/\047/, "\047\047"); print }'
            }

            view_name_for() {
              printf 'subscriptions_%s' "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
            }

            have_user() {
              local user_id="$1"
              local qid
              qid="$(sql_quote "$user_id")"
              [ "$(run_sql "SELECT 1 FROM users WHERE lower(email) = lower('$qid') LIMIT 1;")" = "1" ]
            }

            have_view() {
              local view_name="$1"
              local qview
              qview="$(sql_quote "$view_name")"
              [ "$(run_sql "SELECT 1 FROM pg_matviews WHERE schemaname = 'public' AND matviewname = '$qview' LIMIT 1;")" = "1" ]
            }

            ensure_view() {
              local user_id="$1"
              local view_name
              local qid

              view_name="$(view_name_for "$user_id")"
              qid="$(sql_quote "$user_id")"

              if have_view "$view_name"; then
                return 0
              fi

              run_sql "CREATE MATERIALIZED VIEW ${"$"}view_name AS SELECT cv.* FROM channel_videos cv WHERE EXISTS (SELECT subscriptions FROM users u WHERE cv.ucid = ANY (u.subscriptions) AND u.email = E'${"$"}qid') ORDER BY published DESC;"
            }

            upsert_user_password() {
              local user_id="$1"
              local passfile="$2"
              local password
              local password_hash
              local token
              local qid
              local qhash
              local qtoken

              password="$(tr -d '\r\n' < "$passfile")"
              password_hash="$(mkpasswd --method=bcrypt-a -R 10 "$password")"
              token="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n=')"
              qid="$(sql_quote "$user_id")"
              qhash="$(sql_quote "$password_hash")"
              qtoken="$(sql_quote "$token")"

              if have_user "$user_id"; then
                run_sql "UPDATE users SET password = '$qhash', updated = NOW() WHERE lower(email) = lower('$qid');"
                ensure_view "$user_id"
                return 0
              fi

              run_sql "INSERT INTO users (updated, notifications, subscriptions, email, preferences, password, token, watched, feed_needs_update) VALUES (NOW(), ARRAY[]::text[], ARRAY[]::text[], '$qid', '{}', '$qhash', '$qtoken', ARRAY[]::text[], TRUE);"
              ensure_view "$user_id"
            }

            ensure_user() {
              local user_id="$1"
              local passfile="$2"
              upsert_user_password "$user_id" "$passfile"
            }

            ${passfileLines}

            wait_for_users_table

            ${ensureLines}

            if [ "$PRUNE" = "1" ]; then
              run_sql "SELECT email FROM users ORDER BY email;" | while read -r user_id; do
                [ -n "$user_id" ] || continue
                keep=0
                for declared in $DECLARED; do
                  if [ "$user_id" = "$declared" ]; then
                    keep=1
                    break
                  fi
                done

                if [ "$keep" -eq 0 ]; then
                  view_name="$(view_name_for "$user_id")"
                  qid="$(sql_quote "$user_id")"

                  echo "Removing undeclared user: $user_id"
                  run_sql "DELETE FROM session_ids WHERE lower(email) = lower('$qid');"
                  run_sql "DROP MATERIALIZED VIEW IF EXISTS ${"$"}view_name;"
                  run_sql "DELETE FROM users WHERE lower(email) = lower('$qid');"
                fi
              done
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
        serviceName = "invidious";
        serviceDescription = "Invidious";
      }
    ))
  ]);
}
