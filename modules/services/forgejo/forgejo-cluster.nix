{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.forgejo;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  stagedStateDir = "${cfg.backupDir}${cfg.stateDir}";
  stagedDbPath = "${cfg.backupDir}${config.services.forgejo.database.path}";

  backupPrepScript = pkgs.writeShellScript "alanix-forgejo-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    state_dir=${lib.escapeShellArg cfg.stateDir}
    db_path=${lib.escapeShellArg config.services.forgejo.database.path}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_db_path=${lib.escapeShellArg stagedDbPath}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_state_dir" "$(dirname "$staged_db_path")"

    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${cfg.stateDir}"} "$state_dir" "$staged_state_dir"
    emit_prep_step 2 2 ${lib.escapeShellArg "snapshotting forgejo database"}
    sqlite3 "$db_path" ".backup '$staged_db_path'"

    chown -R forgejo:forgejo "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-forgejo-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    state_dir=${lib.escapeShellArg cfg.stateDir}
    db_path=${lib.escapeShellArg config.services.forgejo.database.path}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_db_path=${lib.escapeShellArg stagedDbPath}
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

    mkdir -p "$(dirname "$db_path")"
    cp -a "$staged_db_path" "$db_path"

    chown -R forgejo:forgejo "$state_dir"
    chown forgejo:forgejo "$db_path"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = config.services.forgejo.database.type == "sqlite3";
        message = "Forgejo cluster mode currently requires the sqlite3 backend.";
      }
    ];

    alanix.clusterServices.forgejo = {
      label = "Forgejo";
      controller = {
        name = "forgejo";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ "forgejo.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [ "forgejo.service" ];
      exposureUnits = [ "forgejo.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 forgejo ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "forgejo";
          label = "Forgejo";
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
    (helpers.mkActiveTargetUnits [ "forgejo.service" ])
  ]);
}
