{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.grocy;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  stagedDataDir = "${cfg.backupDir}${cfg.dataDir}";
  databasePath = "${cfg.dataDir}/grocy.db";
  stagedDatabasePath = "${cfg.backupDir}${databasePath}";

  backupPrepScript = pkgs.writeShellScript "alanix-grocy-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    data_dir=${lib.escapeShellArg cfg.dataDir}
    db_path=${lib.escapeShellArg databasePath}
    staged_data_dir=${lib.escapeShellArg stagedDataDir}
    staged_db_path=${lib.escapeShellArg stagedDatabasePath}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_data_dir" "$(dirname "$staged_db_path")"

    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${cfg.dataDir}"} "$data_dir" "$staged_data_dir"

    emit_prep_step 2 2 ${lib.escapeShellArg "snapshotting grocy database"}
    if [[ -f "$db_path" ]]; then
      sqlite3 "$db_path" ".backup '$staged_db_path'"
    fi

    chown -R grocy:nginx "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-grocy-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    data_dir=${lib.escapeShellArg cfg.dataDir}
    staged_data_dir=${lib.escapeShellArg stagedDataDir}
    trap 'rm -rf "$backup_dir"' EXIT

    if [[ -e "$data_dir" && ! -d "$data_dir" ]]; then
      rm -rf "$data_dir"
    fi
    mkdir -p "$data_dir"

    if [[ -d "$staged_data_dir" ]]; then
      rsync -a --delete "$staged_data_dir"/ "$data_dir"/
    else
      rm -rf "$data_dir"
      mkdir -p "$data_dir"
    fi

    chown -R grocy:nginx "$data_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.hasPrefix "/" cfg.dataDir;
          message = "Grocy cluster mode requires alanix.grocy.dataDir to be an absolute path.";
        }
        {
          assertion = lib.hasPrefix "/" cfg.backupDir;
          message = "Grocy cluster mode requires alanix.grocy.backupDir to be an absolute path.";
        }
      ];

      alanix.clusterServices.grocy = {
        label = "Grocy";
        controller = {
          name = "grocy";
          label = "Grocy";
          backupInterval = cfg.cluster.backupInterval;
          maxBackupAge = cfg.cluster.maxBackupAge;
          activeUnits = [ "phpfpm-grocy.service" ];
          backupPaths = [ cfg.backupDir ];
          preBackupCommand = [ backupPrepScript ];
          postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
          postRestoreCommand = [ restoreScript ];
          restoreTarget = "/";
        };
        targetUnits = [
          "grocy-setup.service"
          "phpfpm-grocy.service"
        ];
        exposureUnits = [
          "nginx.service"
          "phpfpm-grocy.service"
        ];
        tmpfiles = [
          "d ${cfg.backupDir} 0750 grocy ${backupRepoUserGroup} - -"
        ];
        webEndpoints = [
          {
            id = "grocy";
            label = "Grocy";
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
    (helpers.mkActiveTargetUnits [
      "grocy-setup.service"
      "phpfpm-grocy.service"
    ])
  ]);
}
