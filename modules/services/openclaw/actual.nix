{ config, lib, pkgs, pkgs-unstable, ... }:
let
  cfg = config.alanix.openclaw.actual;
  openclawCfg = config.alanix.openclaw;
  openclawUser =
    if openclawCfg.user != null then
      lib.attrByPath [ "alanix" "users" "accounts" openclawCfg.user ] null config
    else
      null;
  openclawHome =
    if openclawUser != null && openclawUser.home.enable then
      openclawUser.home.directory
    else
      null;
  dataDir =
    if lib.hasPrefix "/" cfg.dataDir then
      cfg.dataDir
    else if openclawHome != null then
      "${openclawHome}/${cfg.dataDir}"
    else
      cfg.dataDir;

  actualCliPackage = pkgs.callPackage ./actual-cli { };

  readOnlyDispatch = ''
    case "''${1:-} ''${2:-}" in
      "accounts list"|"accounts balance"|\
      "budgets list"|"budgets month"|"budgets months"|\
      "categories list"|"category-groups list"|\
      "transactions list"|"payees list"|"payees common"|"tags list"|\
      "rules list"|"rules payee-rules"|"schedules list"|"query run"|\
      "server get-id"|"server version")
        ;;
      *)
        echo "actual-budget is configured for read-only access; command denied: ''${1:-} ''${2:-}" >&2
        exit 64
        ;;
    esac
  '';

  actualWrapper = pkgs.writeShellApplication {
    name = "actual-budget";
    runtimeInputs = [ cfg.package pkgs.coreutils ];
    text = ''
      umask 0077

      password_file=${lib.escapeShellArg (if cfg.passwordFile != null then cfg.passwordFile else "")}
      sync_id_file=${lib.escapeShellArg (if cfg.syncIdFile != null then cfg.syncIdFile else "")}

      ${lib.optionalString (!cfg.allowMutations) readOnlyDispatch}

      if [[ ! -r "$password_file" ]]; then
        echo "Actual password file is missing or unreadable" >&2
        exit 78
      fi
      if [[ ! -r "$sync_id_file" ]]; then
        echo "Actual Sync ID file is missing or unreadable" >&2
        exit 78
      fi

      export ACTUAL_SERVER_URL=${lib.escapeShellArg cfg.serverUrl}
      ACTUAL_PASSWORD="$(tr -d '\r\n' < "$password_file")"
      ACTUAL_SYNC_ID="$(tr -d '\r\n' < "$sync_id_file")"
      export ACTUAL_PASSWORD ACTUAL_SYNC_ID
      export ACTUAL_DATA_DIR=${lib.escapeShellArg dataDir}
      export ACTUAL_CACHE_TTL=${lib.escapeShellArg (toString cfg.cacheTtl)}
      export ACTUAL_LOCK_TIMEOUT=${lib.escapeShellArg (toString cfg.lockTimeout)}
      ${lib.optionalString (cfg.encryptionPasswordFile != null) ''
        encryption_password_file=${lib.escapeShellArg cfg.encryptionPasswordFile}
        if [[ ! -r "$encryption_password_file" ]]; then
          echo "Actual encryption password file is missing or unreadable" >&2
          exit 78
        fi
        ACTUAL_ENCRYPTION_PASSWORD="$(tr -d '\r\n' < "$encryption_password_file")"
        export ACTUAL_ENCRYPTION_PASSWORD
      ''}

      mkdir -p "$ACTUAL_DATA_DIR"
      chmod 0700 "$ACTUAL_DATA_DIR"

      exec actual "$@"
    '';
  };
in
{
  options.alanix.openclaw.actual = {
    enable = lib.mkEnableOption "Actual Budget access for OpenClaw";

    package = lib.mkOption {
      type = lib.types.package;
      default = actualCliPackage;
      defaultText = lib.literalExpression "the version-matched official @actual-app/cli package";
      description = "Actual Budget CLI package used by the OpenClaw wrapper.";
    };

    serverUrl = lib.mkOption {
      type = lib.types.str;
      description = "Stable URL of the Actual sync server.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime-only file containing the Actual server password.";
    };

    syncIdFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime-only file containing the budget Sync ID.";
    };

    encryptionPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional runtime-only file containing the budget E2E encryption password.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = ".local/state/actual-cli";
      description = "Private CLI cache directory; relative paths are resolved inside the OpenClaw user's home.";
    };

    cacheTtl = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 60;
      description = "Number of seconds read commands may reuse the local budget cache.";
    };

    lockTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Number of seconds to wait for another CLI process to release the budget lock.";
    };

    allowMutations = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow commands that modify Actual; false exposes only an allowlist of read operations.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = openclawCfg.gateway.enable;
        message = "alanix.openclaw.actual requires alanix.openclaw.gateway.enable.";
      }
      {
        assertion = openclawHome != null;
        message = "alanix.openclaw.actual requires an OpenClaw user with home.enable = true.";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "alanix.openclaw.actual.passwordFile must be set.";
      }
      {
        assertion = cfg.syncIdFile != null;
        message = "alanix.openclaw.actual.syncIdFile must be set.";
      }
      {
        assertion = cfg.package.version == pkgs-unstable.actual-server.version;
        message = "The Actual CLI and actual-server versions must match.";
      }
    ];

    alanix.openclaw.packages = [ actualWrapper ];
  };
}
