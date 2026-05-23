{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.grocy;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;
  hasValue = value: value != null && value != "";

  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };

  baseConfigReady =
    hasValue cfg.hostName
    && hasValue cfg.listenAddress
    && cfg.port != null
    && hasValue cfg.dataDir;

  reconcileEnabled = cfg.users != { };

  sanitizedUsersForRestart =
    lib.mapAttrs (_: u: { inherit (u) passwordSecret; }) cfg.users;

  grocyDb = "${cfg.dataDir}/grocy.db";

  reconcileScript = pkgs.writeShellScript "alanix-grocy-reconcile-users" ''
    set -euo pipefail

    DB=${lib.escapeShellArg grocyDb}
    BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}

    # Grocy initialises grocy.db lazily on the first HTTP request.
    # Prod one request to trigger migrations, then wait for the file.
    wait_for_grocy() {
      local attempts=120
      while [ "$attempts" -gt 0 ]; do
        if curl -sf --max-time 3 "$BASE_URL/" >/dev/null 2>&1; then
          return 0
        fi
        sleep 1
        attempts=$((attempts - 1))
      done
      echo "Timed out waiting for Grocy to become ready." >&2
      return 1
    }

    wait_for_db() {
      local attempts=30
      while [ "$attempts" -gt 0 ]; do
        if [[ -f "$DB" ]]; then
          return 0
        fi
        sleep 1
        attempts=$((attempts - 1))
      done
      echo "Timed out waiting for Grocy database to appear after HTTP trigger." >&2
      return 1
    }

    wait_for_grocy
    wait_for_db

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (username: userCfg: ''
      echo "Reconciling Grocy user: ${username}"
      PASS_${username}="$(tr -d '\r\n' < ${lib.escapeShellArg config.sops.secrets.${userCfg.passwordSecret}.path})"
      HASH_${username}=$(${pkgs.php}/bin/php -r "echo password_hash(getenv('_GROCY_PASS'), PASSWORD_DEFAULT);" \
        _GROCY_PASS="$PASS_${username}")
      existing=$(${pkgs.sqlite}/bin/sqlite3 "$DB" \
        "SELECT COUNT(*) FROM users WHERE username = ${lib.escapeShellArg username};")
      if [ "$existing" = "0" ]; then
        echo "Creating Grocy user: ${username}"
        ${pkgs.sqlite}/bin/sqlite3 "$DB" \
          "INSERT INTO users (username, password, row_created_timestamp) VALUES (${lib.escapeShellArg username}, '$HASH_${username}', datetime('now'));"
      else
        echo "Updating Grocy user password: ${username}"
        ${pkgs.sqlite}/bin/sqlite3 "$DB" \
          "UPDATE users SET password = '$HASH_${username}' WHERE username = ${lib.escapeShellArg username};"
      fi
    '') cfg.users)}

    echo "Grocy user reconciliation complete."
  '';
in
{
  options.alanix.grocy = {
    enable = lib.mkEnableOption "Grocy household management (Alanix)";

    hostName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Browser-facing host name for this Grocy instance.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "127.0.0.1";
      description = "Internal nginx address used by Grocy.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "Internal nginx port used by Grocy.";
    };

    package = lib.mkPackageOption pkgs "grocy" { };

    dataDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/lib/grocy";
      description = "Grocy state directory.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Grocy cluster backup staging directory.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "services.grocy.settings merged into the Grocy NixOS module.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra PHP config appended to Grocy config.php.";
    };

    phpfpmSettings = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf (lib.types.oneOf [
        lib.types.int
        lib.types.str
        lib.types.bool
      ]));
      default = null;
      description = "Optional services.grocy.phpfpm.settings override.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options.passwordSecret = lib.mkOption {
          type = lib.types.str;
          description = "Name of the sops secret containing the plaintext password for Grocy user ${name}.";
        };
      }));
      default = { };
      description = "Declarative Grocy users. Passwords are hashed with bcrypt and upserted into the Grocy SQLite database on each deployment.";
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Grocy through alanix.cluster";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "6h";
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "grocy";
      serviceDescription = "Grocy";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.hostName;
            message = "alanix.grocy.hostName must be set when alanix.grocy.enable = true.";
          }
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.grocy.listenAddress must be set when alanix.grocy.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.grocy.port must be set when alanix.grocy.enable = true.";
          }
          {
            assertion = cfg.dataDir == null || lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.grocy.dataDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.grocy.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.grocy.cluster.enable requires alanix.grocy.backupDir to be set.";
          }
        ]
        ++ lib.mapAttrsToList (username: userCfg: {
          assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
          message = "alanix.grocy.users.${username}.passwordSecret '${userCfg.passwordSecret}' must be declared as a sops secret.";
        }) cfg.users
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.grocy.expose";
        };

      services.grocy = lib.mkIf baseConfigReady (
        {
          enable = true;
          package = cfg.package;
          hostName = cfg.hostName;
          dataDir = cfg.dataDir;
          settings = cfg.settings;
          extraConfig = cfg.extraConfig;
          nginx.enableSSL = false;
        }
        // lib.optionalAttrs (cfg.phpfpmSettings != null) {
          phpfpm.settings = cfg.phpfpmSettings;
        }
      );

      systemd.services.grocy-reconcile-users = lib.mkIf (reconcileEnabled && baseConfigReady) {
        description = "Reconcile Grocy users";
        after = [ "phpfpm-grocy.service" "sops-nix.service" ];
        wants = [ "phpfpm-grocy.service" "sops-nix.service" ];
        partOf = [ "phpfpm-grocy.service" ];
        wantedBy = [ "phpfpm-grocy.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "grocy";
          Group = "nginx";
          UMask = "0077";
        };

        path = [ pkgs.php pkgs.sqlite pkgs.curl ];

        script = builtins.readFile reconcileScript;

        restartTriggers = [ (builtins.toJSON sanitizedUsersForRestart) ];
      };

      system.activationScripts.alanixGrocyReconcileUsers =
        lib.mkIf (baseConfigReady && reconcileEnabled) {
          deps = [ "etc" "setupSecrets" ];
          text = ''
            if ${pkgs.systemd}/bin/systemctl --quiet is-active phpfpm-grocy.service; then
              ${pkgs.systemd}/bin/systemctl daemon-reload
              ${pkgs.systemd}/bin/systemctl start grocy-reconcile-users.service || true
            fi
          '';
        };

      services.nginx.virtualHosts = lib.mkIf baseConfigReady {
        ${cfg.hostName} = {
          listen = [
            {
              addr = cfg.listenAddress;
              port = cfg.port;
              ssl = false;
            }
          ];
          forceSSL = lib.mkForce false;
          enableACME = lib.mkForce false;
          addSSL = lib.mkForce false;
        };
      };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "grocy";
        serviceDescription = "Grocy";
      }
    ))
  ]);
}
