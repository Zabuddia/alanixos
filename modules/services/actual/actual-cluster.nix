{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.actual;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  dataDir = "/var/lib/actual";

  backupPrepScript = pkgs.writeShellScript "alanix-actual-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"

    emit_prep_step 1 1 ${lib.escapeShellArg "snapshotting actual data directory"}
    if [[ -d ${lib.escapeShellArg dataDir} ]]; then
      rsync -a ${lib.escapeShellArg dataDir}/ "$backup_dir"/
    fi

    chown -R actual:actual "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-actual-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    data_dir=${lib.escapeShellArg dataDir}
    trap 'rm -rf "$backup_dir"' EXIT

    if [[ -e "$data_dir" && ! -d "$data_dir" ]]; then
      rm -rf "$data_dir"
    fi
    mkdir -p "$data_dir"
    if [[ -d "$backup_dir" ]]; then
      rsync -a --delete "$backup_dir"/ "$data_dir"/
    else
      rm -rf "$data_dir"
      mkdir -p "$data_dir"
    fi
    chown -R actual:actual "$data_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      alanix.clusterServices.actual = {
        label = "Actual";
        controller = {
          name = "actual";
          backupInterval = cfg.cluster.backupInterval;
          maxBackupAge = cfg.cluster.maxBackupAge;
          activeUnits = [ "actual.service" ];
          backupPaths = [ cfg.backupDir ];
          preBackupCommand = [ backupPrepScript ];
          postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
          postRestoreCommand = [ restoreScript ];
          restoreTarget = "/";
        };
        targetUnits = [ "actual.service" ];
        exposureUnits = [ "actual.service" ];
        tmpfiles = [
          "d ${cfg.backupDir} 0750 actual ${backupRepoUserGroup} - -"
        ];
        webEndpoints = [
          {
            id = "actual";
            label = "Actual";
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
    (helpers.mkActiveTargetUnits [ "actual.service" ])
  ]);
}
