{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.vaultwarden;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  backupPrepScript = pkgs.writeShellScript "alanix-vaultwarden-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}

    ${backupPrepProgressHelpers}

    mkdir -p "$backup_dir"
    chown -R vaultwarden:vaultwarden "$backup_dir"
    chmod -R u=rwX,go= "$backup_dir"

    emit_prep_step 1 1 ${lib.escapeShellArg "running vaultwarden backup service"}
    systemctl start backup-vaultwarden.service

    if [[ -d "$backup_dir" ]]; then
      chgrp -R "$backup_group" "$backup_dir"
      chmod -R u=rwX,g=rX,o= "$backup_dir"
    fi
  '';

  restoreScript = pkgs.writeShellScript "alanix-vaultwarden-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    data_dir=/var/lib/vaultwarden
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
    chown -R vaultwarden:vaultwarden "$data_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = config.services.vaultwarden.dbBackend == "sqlite";
        message = "Vaultwarden cluster mode currently requires the sqlite backend.";
      }
      {
        assertion = config.systemd.services ? backup-vaultwarden;
        message = "Vaultwarden cluster mode requires backup-vaultwarden.service to exist.";
      }
    ];

    alanix.clusterServices.vaultwarden = {
      label = "Vaultwarden";
      controller = {
        name = "vaultwarden";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ "vaultwarden.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [ "vaultwarden.service" ];
      exposureUnits = [ "vaultwarden.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 vaultwarden ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "vaultwarden";
          label = "Vaultwarden";
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
    (helpers.mkActiveTargetUnits [ "vaultwarden.service" ])
    {
      systemd.services.backup-vaultwarden.wantedBy = lib.mkForce [ ];
      systemd.timers.backup-vaultwarden.wantedBy = lib.mkForce [ ];
    }
  ]);
}
