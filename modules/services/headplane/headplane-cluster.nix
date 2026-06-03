{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.headplane;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  headplaneUser = config.services.headscale.user;
  headplaneGroup = config.services.headscale.group;
  stagedStateDir = "${cfg.backupDir}${cfg.stateDir}";
  stagedDbPath = "${stagedStateDir}/hp_persist.db";

  backupPrepScript = pkgs.writeShellScript "alanix-headplane-cluster-backup-runtime" ''
    set -euo pipefail

    state_dir=${lib.escapeShellArg cfg.stateDir}
    backup_dir=${lib.escapeShellArg cfg.backupDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_db_path=${lib.escapeShellArg stagedDbPath}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_state_dir"

    emit_prep_step 1 2 ${lib.escapeShellArg "staging Headplane state"}
    if [[ -d "$state_dir" ]]; then
      ${pkgs.rsync}/bin/rsync -a --delete \
        --exclude hp_persist.db \
        --exclude hp_persist.db-wal \
        --exclude hp_persist.db-shm \
        "$state_dir"/ "$staged_state_dir"/
    fi

    emit_prep_step 2 2 ${lib.escapeShellArg "snapshotting Headplane sqlite database"}
    if [[ -f "$state_dir/hp_persist.db" ]]; then
      ${pkgs.sqlite}/bin/sqlite3 "$state_dir/hp_persist.db" ".backup '$staged_db_path'"
    fi

    chown -R ${lib.escapeShellArg headplaneUser}:${lib.escapeShellArg headplaneGroup} "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-headplane-cluster-restore-runtime" ''
    set -euo pipefail

    state_dir=${lib.escapeShellArg cfg.stateDir}
    backup_dir=${lib.escapeShellArg cfg.backupDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_db_path=${lib.escapeShellArg stagedDbPath}
    trap 'rm -rf "$backup_dir"' EXIT

    if [[ -e "$state_dir" && ! -d "$state_dir" ]]; then
      rm -rf "$state_dir"
    fi

    mkdir -p "$state_dir"
    if [[ -d "$staged_state_dir" ]]; then
      ${pkgs.rsync}/bin/rsync -a --delete "$staged_state_dir"/ "$state_dir"/
    else
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
    fi

    if [[ -f "$staged_db_path" ]]; then
      install -m0600 -o ${lib.escapeShellArg headplaneUser} -g ${lib.escapeShellArg headplaneGroup} "$staged_db_path" "$state_dir/hp_persist.db"
      rm -f "$state_dir/hp_persist.db-wal" "$state_dir/hp_persist.db-shm"
    fi

    chown -R ${lib.escapeShellArg headplaneUser}:${lib.escapeShellArg headplaneGroup} "$state_dir"
    chmod -R u=rwX,go= "$state_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      alanix.clusterServices.headplane = {
        label = "Headplane";
        controller = {
          name = "headplane";
          backupInterval = cfg.cluster.backupInterval;
          maxBackupAge = cfg.cluster.maxBackupAge;
          activeUnits = [ "headplane.service" ];
          backupPaths = [ cfg.backupDir ];
          preBackupCommand = [ backupPrepScript ];
          postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
          postRestoreCommand = [ restoreScript ];
          restoreTarget = "/";
        };
        targetUnits = [ "headplane.service" ];
        exposureUnits = [ "headplane.service" ];
        tmpfiles = [
          "d ${cfg.backupDir} 0750 ${headplaneUser} ${backupRepoUserGroup} - -"
        ];
        webEndpoints = [
          {
            id = "headplane";
            label = "Headplane";
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

    (helpers.mkActiveTargetUnits [ "headplane.service" ])
  ]);
}
