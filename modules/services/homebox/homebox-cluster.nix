{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.homebox;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  backupPrepScript = pkgs.writeShellScript "alanix-homebox-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    data_dir=${lib.escapeShellArg cfg.dataDir}
    db_path=${lib.escapeShellArg "${cfg.dataDir}/data/homebox.db"}
    staged_data_dir=${lib.escapeShellArg "${cfg.backupDir}${cfg.dataDir}"}
    staged_db_path=${lib.escapeShellArg "${cfg.backupDir}${cfg.dataDir}/data/homebox.db"}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_data_dir"

    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${cfg.dataDir}"} "$data_dir" "$staged_data_dir"

    emit_prep_step 2 2 ${lib.escapeShellArg "snapshotting homebox database"}
    if [[ -f "$db_path" ]]; then
      mkdir -p "$(dirname "$staged_db_path")"
      sqlite3 "$db_path" ".backup '$staged_db_path'"
    fi

    chown -R homebox:homebox "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-homebox-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    data_dir=${lib.escapeShellArg cfg.dataDir}
    staged_data_dir=${lib.escapeShellArg "${cfg.backupDir}${cfg.dataDir}"}
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

    chown -R homebox:homebox "$data_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.hasPrefix "/" cfg.dataDir;
          message = "Homebox cluster mode requires alanix.homebox.dataDir to be an absolute path.";
        }
        {
          assertion = lib.hasPrefix "/" cfg.backupDir;
          message = "Homebox cluster mode requires alanix.homebox.backupDir to be an absolute path.";
        }
      ];

      alanix.clusterServices.homebox = {
        label = "Homebox";
        controller = {
          name = "homebox";
          label = "Homebox";
          backupInterval = cfg.cluster.backupInterval;
          maxBackupAge = cfg.cluster.maxBackupAge;
          activeUnits = [ "homebox.service" ];
          backupPaths = [ cfg.backupDir ];
          preBackupCommand = [ backupPrepScript ];
          postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
          postRestoreCommand = [ restoreScript ];
          restoreTarget = "/";
        };
        targetUnits = [ "homebox.service" ];
        exposureUnits = [ "homebox.service" ];
        tmpfiles = [
          "d ${cfg.backupDir} 0750 homebox ${backupRepoUserGroup} - -"
        ];
        webEndpoints = [
          {
            id = "homebox";
            label = "Homebox";
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
    (helpers.mkActiveTargetUnits [ "homebox.service" ])
  ]);
}
