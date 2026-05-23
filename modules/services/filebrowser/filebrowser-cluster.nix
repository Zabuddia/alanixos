{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.filebrowser;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  stagedDatabasePath = "${cfg.backupDir}${cfg.database}";

  backupPrepScript = pkgs.writeShellScript "alanix-filebrowser-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    db_path=${lib.escapeShellArg cfg.database}
    staged_db_path=${lib.escapeShellArg stagedDatabasePath}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$(dirname "$staged_db_path")"

    emit_prep_step 1 1 ${lib.escapeShellArg "snapshotting filebrowser database"}
    if [[ -f "$db_path" ]]; then
      cp -a "$db_path" "$staged_db_path"
    fi

    chown -R filebrowser:filebrowser "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-filebrowser-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    db_path=${lib.escapeShellArg cfg.database}
    staged_db_path=${lib.escapeShellArg stagedDatabasePath}
    trap 'rm -rf "$backup_dir"' EXIT

    mkdir -p "$(dirname "$db_path")"

    if [[ -f "$staged_db_path" ]]; then
      cp -a "$staged_db_path" "$db_path"
      chown filebrowser:filebrowser "$db_path"
    fi
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.root;
        message = "File Browser cluster mode requires alanix.filebrowser.root to be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.database;
        message = "File Browser cluster mode requires alanix.filebrowser.database to be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.backupDir;
        message = "File Browser cluster mode requires alanix.filebrowser.backupDir to be an absolute path.";
      }
    ];

    alanix.clusterServices.filebrowser = {
      label = "File Browser";
      controller = {
        name = "filebrowser";
        label = "File Browser";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ "filebrowser.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [ "filebrowser.service" ];
      exposureUnits = [ "filebrowser.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 filebrowser ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "filebrowser";
          label = "File Browser";
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
    (helpers.mkActiveTargetUnits [ "filebrowser.service" ])
  ]);
}
