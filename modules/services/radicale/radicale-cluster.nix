{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.radicale;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  stagedStorageDir = "${cfg.backupDir}${cfg.storageDir}";

  backupPrepScript = pkgs.writeShellScript "alanix-radicale-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    storage_dir=${lib.escapeShellArg cfg.storageDir}
    staged_storage_dir=${lib.escapeShellArg stagedStorageDir}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"

    rsync_prep_step 1 1 ${lib.escapeShellArg "staging ${cfg.storageDir}"} "$storage_dir" "$staged_storage_dir"

    chown -R radicale:radicale "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-radicale-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    storage_dir=${lib.escapeShellArg cfg.storageDir}
    staged_storage_dir=${lib.escapeShellArg stagedStorageDir}
    trap 'rm -rf "$backup_dir"' EXIT

    if [[ -e "$storage_dir" && ! -d "$storage_dir" ]]; then
      rm -rf "$storage_dir"
    fi
    mkdir -p "$storage_dir"

    if [[ -d "$staged_storage_dir" ]]; then
      rsync -a --delete "$staged_storage_dir"/ "$storage_dir"/
    else
      rm -rf "$storage_dir"
      mkdir -p "$storage_dir"
    fi

    chown -R radicale:radicale "$storage_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.storageDir;
        message = "Radicale cluster mode requires alanix.radicale.storageDir to be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.backupDir;
        message = "Radicale cluster mode requires alanix.radicale.backupDir to be an absolute path.";
      }
    ];

    alanix.clusterServices.radicale = {
      label = "Radicale";
      controller = {
        name = "radicale";
        label = "Radicale";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ "radicale.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [ "radicale.service" ];
      exposureUnits = [ "radicale.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 radicale ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "radicale";
          label = "Radicale";
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
    (helpers.mkActiveTargetUnits [ "radicale.service" ])
  ]);
}
