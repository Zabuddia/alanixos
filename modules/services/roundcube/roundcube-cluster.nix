{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.roundcube;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable && cfg.backupDir != null;

  stateDir = "/var/lib/roundcube";
  stagedStateDir = "${cfg.backupDir}${stateDir}";
  stagedDatabaseDump = "${cfg.backupDir}/database/roundcube.pgcustom";

  backupPrepScript = pkgs.writeShellScript "alanix-roundcube-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    state_dir=${lib.escapeShellArg stateDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_database=${lib.escapeShellArg cfg.database.dbname}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_state_dir" "$(dirname "$staged_dump")"
    chown -R roundcube:roundcube "$backup_dir"

    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${stateDir}"} "$state_dir" "$staged_state_dir"

    emit_prep_step 2 2 ${lib.escapeShellArg "dumping roundcube database"}
    runuser -u postgres -- pg_dump \
      --format=custom \
      "$pg_database" > "$staged_dump"

    chown -R roundcube:roundcube "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-roundcube-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    state_dir=${lib.escapeShellArg stateDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_user=${lib.escapeShellArg cfg.database.username}
    pg_database=${lib.escapeShellArg cfg.database.dbname}
    restore_dump=""
    cleanup() {
      if [[ -n "$restore_dump" && -e "$restore_dump" ]]; then
        rm -f "$restore_dump"
      fi
      rm -rf "$backup_dir"
    }
    trap cleanup EXIT

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

    chown -R roundcube:roundcube "$state_dir"

    if [[ -f "$staged_dump" ]]; then
      restore_dump="$(mktemp /var/tmp/alanix-roundcube-restore-XXXXXX.pgcustom)"
      install -m 0600 -o postgres -g postgres "$staged_dump" "$restore_dump"

      runuser -u postgres -- dropdb --if-exists "$pg_database"
      runuser -u postgres -- createdb --owner="$pg_user" "$pg_database"
      runuser -u postgres -- pg_restore \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        --role="$pg_user" \
        --exit-on-error \
        --dbname="$pg_database" \
        "$restore_dump"
    fi
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.backupDir;
        message = "Roundcube cluster mode requires alanix.roundcube.backupDir to be an absolute path.";
      }
      {
        assertion = cfg.database.host == "localhost";
        message = "Roundcube cluster mode currently requires a locally managed PostgreSQL database.";
      }
      {
        assertion = cfg.database.username == cfg.database.dbname;
        message = "Roundcube cluster mode requires alanix.roundcube.database.username to match alanix.roundcube.database.dbname.";
      }
    ];

    alanix.clusterServices.roundcube = {
      label = "Roundcube";
      needsPostgresql = true;
      controller = {
        name = "roundcube";
        label = "Roundcube";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ "phpfpm-roundcube.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits = [
        "roundcube-setup.service"
        "phpfpm-roundcube.service"
      ];
      exposureUnits = [
        "nginx.service"
        "phpfpm-roundcube.service"
      ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 roundcube ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "roundcube";
          label = "Roundcube";
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
      "roundcube-setup.service"
      "phpfpm-roundcube.service"
    ])
  ]);
}
