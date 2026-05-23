{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.navidrome;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;
  clusteredPaths = [ cfg.dataDir ];
  prepStepCount = builtins.length clusteredPaths + 1;

  backupPrepScript = pkgs.writeShellScript "alanix-navidrome-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    data_dir=${lib.escapeShellArg cfg.dataDir}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"

    ${lib.concatStringsSep "\n" (builtins.genList
      (index:
        let
          path = builtins.elemAt clusteredPaths index;
        in
        ''
          rsync_prep_step ${toString (index + 1)} ${toString prepStepCount} ${lib.escapeShellArg "staging ${path}"} ${lib.escapeShellArg path} ${lib.escapeShellArg "${cfg.backupDir}${path}"}
        '')
      (builtins.length clusteredPaths))}

    emit_prep_step ${toString prepStepCount} ${toString prepStepCount} ${lib.escapeShellArg "snapshotting navidrome sqlite databases"}
    shopt -s globstar nullglob
    for db_path in "$data_dir"/**/*.db "$data_dir"/*.db; do
      [[ -f "$db_path" ]] || continue
      staged_db="$backup_dir$db_path"
      mkdir -p "$(dirname "$staged_db")"
      sqlite3 "$db_path" ".backup '$staged_db'"
    done
    shopt -u globstar nullglob

    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-navidrome-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    trap 'rm -rf "$backup_dir"' EXIT

    restore_dir() {
      local target="$1"
      local staged_dir="$backup_dir$target"

      if [[ -e "$target" && ! -d "$target" ]]; then
        rm -rf "$target"
      fi
      mkdir -p "$target"

      if [[ -d "$staged_dir" ]]; then
        rsync -a --delete "$staged_dir"/ "$target"/
      else
        rm -rf "$target"
        mkdir -p "$target"
      fi
    }

    ${lib.concatMapStringsSep "\n" (path: ''
      restore_dir ${lib.escapeShellArg path}
    '') clusteredPaths}

    chown -R navidrome:navidrome ${lib.escapeShellArg cfg.dataDir}
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.dataDir;
        message = "Navidrome cluster mode requires alanix.navidrome.dataDir to be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.backupDir;
        message = "Navidrome cluster mode requires alanix.navidrome.backupDir to be an absolute path.";
      }
    ];

    alanix.clusterServices.navidrome = {
      label = "Navidrome";
      controller = {
        name = "navidrome";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ "navidrome.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [ "navidrome.service" ];
      exposureUnits = [ "navidrome.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 navidrome ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "navidrome";
          label = "Navidrome";
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
    (helpers.mkActiveTargetUnits [ "navidrome.service" ])
  ]);
}
