{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.openwebui;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  defaultDatabaseUrl = "sqlite:///${cfg.stateDir}/data/webui.db";
  stagedStateDir = "${cfg.backupDir}${cfg.stateDir}";
  environmentFile = if cfg.environmentFile != null then cfg.environmentFile else "";

  backupPrepScript = pkgs.writeShellScript "alanix-openwebui-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    state_dir=${lib.escapeShellArg cfg.stateDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    environment_file=${lib.escapeShellArg environmentFile}
    default_database_url=${lib.escapeShellArg defaultDatabaseUrl}

    ${backupPrepProgressHelpers}

    database_url="$default_database_url"
    if [[ -n "$environment_file" && -f "$environment_file" ]]; then
      set -a
      source "$environment_file"
      set +a
      if [[ -n "''${DATABASE_URL:-}" ]]; then
        database_url="$DATABASE_URL"
      fi
    fi

    case "$database_url" in
      sqlite:///*)
        db_path="''${database_url#sqlite:///}"
        ;;
      *)
        echo "Open WebUI cluster mode currently requires a local sqlite DATABASE_URL." >&2
        exit 1
        ;;
    esac

    case "$db_path" in
      "$state_dir"/*)
        ;;
      *)
        echo "Open WebUI cluster mode currently requires the sqlite database to live under $state_dir." >&2
        exit 1
        ;;
    esac

    staged_db_path="$staged_state_dir''${db_path#"$state_dir"}"

    rm -rf "$backup_dir"
    mkdir -p "$staged_state_dir" "$(dirname "$staged_db_path")"
    chown -R open-webui:open-webui "$backup_dir"

    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${cfg.stateDir}"} "$state_dir" "$staged_state_dir"

    emit_prep_step 2 2 ${lib.escapeShellArg "snapshotting open webui database"}
    if [[ -f "$db_path" ]]; then
      sqlite3 "$db_path" ".backup '$staged_db_path'"
    fi

    chown -R open-webui:open-webui "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-openwebui-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    state_dir=${lib.escapeShellArg cfg.stateDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    trap 'rm -rf "$backup_dir"' EXIT

    if [[ -e "$state_dir" && ! -d "$state_dir" ]]; then
      rm -rf "$state_dir"
    fi
    mkdir -p "$state_dir"

    if [[ -d "$staged_state_dir" ]]; then
      rsync -a --delete "$staged_state_dir"/ "$state_dir"/
    else
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
    fi

    chown -R open-webui:open-webui "$state_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.stateDir;
        message = "Open WebUI cluster mode requires alanix.openwebui.stateDir to be an absolute path.";
      }
    ];

    alanix.clusterServices.openwebui = {
      label = "Open WebUI";
      controller = {
        name = "openwebui";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ "open-webui.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [ "open-webui.service" ];
      exposureUnits = [ "open-webui.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 open-webui ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "openwebui";
          label = "Open WebUI";
          endpoint = {
            address = cfg.listenAddress;
            port = cfg.port;
            protocol = "http";
          };
          expose = cfg.expose;
        }
      ];
    };
    }
    (helpers.mkActiveTargetUnits [ "open-webui.service" ])
  ]);
}
