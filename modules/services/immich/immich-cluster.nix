{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.immich;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  mediaDir = toString cfg.mediaLocation;
  stagedMediaDir = "${cfg.backupDir}${mediaDir}";
  stagedDatabaseDump = "${cfg.backupDir}/database/immich.pgcustom";

  backupPrepScript = pkgs.writeShellScript "alanix-immich-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    media_dir=${lib.escapeShellArg mediaDir}
    staged_media_dir=${lib.escapeShellArg stagedMediaDir}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_host=${lib.escapeShellArg config.services.immich.database.host}
    pg_user=${lib.escapeShellArg config.services.immich.database.user}
    pg_database=${lib.escapeShellArg config.services.immich.database.name}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_media_dir" "$(dirname "$staged_dump")"
    chown -R immich:immich "$backup_dir"

    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${mediaDir}"} "$media_dir" "$staged_media_dir"

    emit_prep_step 2 2 ${lib.escapeShellArg "dumping immich database"}
    runuser -u immich -- env \
      PGHOST="$pg_host" \
      PGUSER="$pg_user" \
      PGDATABASE="$pg_database" \
      pg_dump \
        --format=custom \
        --file="$staged_dump" \
        "$pg_database"

    chown -R immich:immich "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-immich-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    media_dir=${lib.escapeShellArg mediaDir}
    staged_media_dir=${lib.escapeShellArg stagedMediaDir}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_host=${lib.escapeShellArg config.services.immich.database.host}
    pg_user=${lib.escapeShellArg config.services.immich.database.user}
    pg_database=${lib.escapeShellArg config.services.immich.database.name}
    restore_dump=""
    cleanup() {
      if [[ -n "$restore_dump" && -e "$restore_dump" ]]; then
        rm -f "$restore_dump"
      fi
      rm -rf "$backup_dir"
    }
    trap cleanup EXIT

    if [[ -e "$media_dir" && ! -d "$media_dir" ]]; then
      rm -rf "$media_dir"
    fi
    mkdir -p "$media_dir"

    if [[ -d "$staged_media_dir" ]]; then
      rsync -a --delete "$staged_media_dir"/ "$media_dir"/
    else
      rm -rf "$media_dir"
      mkdir -p "$media_dir"
    fi

    chown -R immich:immich "$media_dir"

    if [[ -f "$staged_dump" ]]; then
      restore_dump="$(mktemp /var/tmp/alanix-immich-restore-XXXXXX.pgcustom)"
      install -m 0600 -o postgres -g postgres "$staged_dump" "$restore_dump"

      runuser -u postgres -- env \
        PGHOST="$pg_host" \
        dropdb --if-exists "$pg_database"

      runuser -u postgres -- env \
        PGHOST="$pg_host" \
        createdb --owner="$pg_user" "$pg_database"

      runuser -u postgres -- env \
        PGHOST="$pg_host" \
        pg_restore \
          --clean \
          --if-exists \
          --no-privileges \
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
        assertion = config.services.immich.database.enable;
        message = "Immich cluster mode currently requires a locally managed PostgreSQL database.";
      }
      {
        assertion = lib.hasPrefix "/" config.services.immich.database.host;
        message = "Immich cluster mode currently requires PostgreSQL on the local host via unix socket.";
      }
      {
        assertion = config.services.immich.database.user == config.services.immich.user;
        message = "Immich cluster mode currently requires services.immich.database.user to match services.immich.user.";
      }
    ];

    alanix.clusterServices.immich = {
      label = "Immich";
      needsPostgresql = true;
      controller = {
        name = "immich";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits =
          [ "immich-server.service" ]
          ++ lib.optionals cfg.machineLearning.enable [ "immich-machine-learning.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits =
        [ "immich-server.service" ]
        ++ lib.optionals cfg.machineLearning.enable [ "immich-machine-learning.service" ];
      exposureUnits =
        [ "immich-server.service" ]
        ++ lib.optionals cfg.machineLearning.enable [ "immich-machine-learning.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 immich ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "immich";
          label = "Immich";
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
    (helpers.mkActiveTargetUnits [ "immich-server.service" ])
    (lib.mkIf cfg.machineLearning.enable (helpers.mkActiveTargetUnits [ "immich-machine-learning.service" ]))
  ]);
}
