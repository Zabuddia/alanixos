{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.firefly-iii;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  dataDir = config.services.firefly-iii.dataDir;

  backupPrepScript = pkgs.writeShellScript "alanix-firefly-iii-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"

    emit_prep_step 1 1 ${lib.escapeShellArg "snapshotting firefly-iii data directory"}
    if [[ -d ${lib.escapeShellArg dataDir} ]]; then
      rsync -a ${lib.escapeShellArg dataDir}/ "$backup_dir"/
    fi

    chown -R firefly-iii:firefly-iii "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-firefly-iii-cluster-restore-runtime" ''
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
    chown -R firefly-iii:firefly-iii "$data_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      alanix.clusterServices.firefly-iii = {
        label = "Firefly III";
        controller = {
          name = "firefly-iii";
          backupInterval = cfg.cluster.backupInterval;
          maxBackupAge = cfg.cluster.maxBackupAge;
          activeUnits = [ "phpfpm-firefly-iii.service" ];
          backupPaths = [ cfg.backupDir ];
          preBackupCommand = [ backupPrepScript ];
          postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
          postRestoreCommand = [ restoreScript ];
          restoreTarget = "/";
        };
        targetUnits = [ "phpfpm-firefly-iii.service" ];
        exposureUnits = [ "phpfpm-firefly-iii.service" "nginx.service" ];
        tmpfiles = [
          "d ${cfg.backupDir} 0750 firefly-iii ${backupRepoUserGroup} - -"
        ];
        webEndpoints = [
          {
            id = "firefly-iii";
            label = "Firefly III";
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
    (helpers.mkActiveTargetUnits [ "phpfpm-firefly-iii.service" ])
  ]);
}
