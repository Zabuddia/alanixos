{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.homebox;
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
    hasValue cfg.listenAddress
    && cfg.port != null;

  reconcileEnabled = cfg.users != { };

  sanitizedUsersForRestart =
    lib.mapAttrs (_: u: { inherit (u) name email passwordSecret; }) cfg.users;

  reconcileScript = ''
    set -euo pipefail

    BASE_URL=${lib.escapeShellArg "http://${cfg.listenAddress}:${toString cfg.port}"}

    wait_for_server() {
      local attempts=120
      while [ "$attempts" -gt 0 ]; do
        # Any HTTP response (even 400/422) means the server is up
        local status
        status=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 \
          -X POST "$BASE_URL/api/v1/users/login" \
          -H "Content-Type: application/json" \
          -d '{}' 2>/dev/null || true)
        if [[ "$status" =~ ^[0-9]+$ ]] && [ "$status" != "000" ]; then
          return 0
        fi
        sleep 1
        attempts=$((attempts - 1))
      done
      echo "Timed out waiting for Homebox to become ready." >&2
      return 1
    }

    login() {
      local email="$1"
      local password="$2"
      curl -sS -o /dev/null -w "%{http_code}" \
        -X POST "$BASE_URL/api/v1/users/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$email\", \"password\": \"$password\"}"
    }

    register() {
      local name="$1"
      local email="$2"
      local password="$3"
      local status
      status=$(curl -sS -o /dev/null -w "%{http_code}" \
        -X POST "$BASE_URL/api/v1/users/register" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$name\", \"email\": \"$email\", \"password\": \"$password\"}")
      echo "$status"
    }

    wait_for_server

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (username: userCfg: ''
      echo "Reconciling Homebox user: ${username}"
      PASS_${username}="$(tr -d '\r\n' < ${lib.escapeShellArg config.sops.secrets.${userCfg.passwordSecret}.path})"
      login_status=$(login ${lib.escapeShellArg userCfg.email} "$PASS_${username}")
      if [ "$login_status" = "200" ]; then
        echo "Homebox user ${username} already exists and password is correct."
      else
        echo "Homebox user ${username} not found or password mismatch, attempting registration..."
        reg_status=$(register ${lib.escapeShellArg userCfg.name} ${lib.escapeShellArg userCfg.email} "$PASS_${username}")
        if [ "$reg_status" = "200" ] || [ "$reg_status" = "204" ]; then
          echo "Homebox user ${username} registered successfully."
        else
          echo "Warning: Failed to register Homebox user ${username} (HTTP $reg_status). Registration may be disabled." >&2
        fi
      fi
    '') cfg.users)}

    echo "Homebox user reconciliation complete."
  '';
in
{
  options.alanix.homebox = {
    enable = lib.mkEnableOption "Homebox inventory management (Alanix)";

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "127.0.0.1";
      description = "Bind address for Homebox.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "HTTP port for Homebox.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/homebox";
      description = "Homebox state directory.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    allowRegistration = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow new user registration. Must be true for the first deployment to create initial users.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
      default = { };
      description = "Extra environment variables merged into the Homebox service. See upstream docs for available options.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Display name for this Homebox user.";
          };

          email = lib.mkOption {
            type = lib.types.str;
            description = "Email address used to log in.";
          };

          passwordSecret = lib.mkOption {
            type = lib.types.str;
            description = "Name of the sops secret containing the user's plaintext password.";
          };
        };
      }));
      default = { };
      description = ''
        Declarative Homebox users. Each user is created via the registration API on first deployment.
        Requires alanix.homebox.allowRegistration = true on the initial deployment.
      '';
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-manage Homebox through alanix.cluster";

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
      serviceName = "homebox";
      serviceDescription = "Homebox";
      defaultPublicPort = 80;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = hasValue cfg.listenAddress;
            message = "alanix.homebox.listenAddress must be set when alanix.homebox.enable = true.";
          }
          {
            assertion = cfg.port != null;
            message = "alanix.homebox.port must be set when alanix.homebox.enable = true.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.dataDir;
            message = "alanix.homebox.dataDir must be an absolute path.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.homebox.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.homebox.cluster.enable requires alanix.homebox.backupDir to be set.";
          }
        ]
        ++ lib.mapAttrsToList (username: userCfg: {
          assertion = lib.hasAttrByPath [ "sops" "secrets" userCfg.passwordSecret ] config;
          message = "alanix.homebox.users.${username}.passwordSecret '${userCfg.passwordSecret}' must be declared as a sops secret.";
        }) cfg.users
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.homebox.expose";
        };

      services.homebox = lib.mkIf baseConfigReady {
        enable = true;
        settings = lib.mkMerge [
          {
            HBOX_WEB_HOST = cfg.listenAddress;
            HBOX_WEB_PORT = toString cfg.port;
            HBOX_STORAGE_CONN_STRING = "file://${cfg.dataDir}";
            HBOX_DATABASE_SQLITE_PATH = "${cfg.dataDir}/data/homebox.db?_pragma=busy_timeout=999&_pragma=journal_mode=WAL&_fk=1";
            HBOX_OPTIONS_ALLOW_REGISTRATION = if cfg.allowRegistration then "true" else "false";
            HOME = cfg.dataDir;
            TMPDIR = "${cfg.dataDir}/tmp";
          }
          cfg.settings
        ];
      };

      systemd.services.homebox-reconcile-users = lib.mkIf (reconcileEnabled && baseConfigReady) {
        description = "Reconcile Homebox users";
        after = [ "homebox.service" "sops-nix.service" ];
        wants = [ "homebox.service" "sops-nix.service" ];
        partOf = [ "homebox.service" ];
        wantedBy = [ "homebox.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          UMask = "0077";
        };

        path = [ pkgs.coreutils pkgs.curl ];

        script = reconcileScript;

        restartTriggers = [ (builtins.toJSON sanitizedUsersForRestart) ];
      };

      system.activationScripts.alanixHomeboxReconcileUsers =
        lib.mkIf (baseConfigReady && reconcileEnabled) {
          deps = [ "etc" "setupSecrets" ];
          text = ''
            if ${pkgs.systemd}/bin/systemctl --quiet is-active homebox.service; then
              ${pkgs.systemd}/bin/systemctl daemon-reload
              ${pkgs.systemd}/bin/systemctl start homebox-reconcile-users.service || true
            fi
          '';
        };
    }

    (lib.mkIf (baseConfigReady && !clusterCfg.enable) (
      serviceExposure.mkConfig {
        inherit config endpoint exposeCfg;
        serviceName = "homebox";
        serviceDescription = "Homebox";
      }
    ))
  ]);
}
