{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.nextcloud;
  collaboraCfg = cfg.collabora;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  dataDir = if cfg.dataDir != null then cfg.dataDir else cfg.stateDir;
  clusteredPaths = lib.unique (
    [ cfg.stateDir ]
    ++ lib.optional (dataDir != cfg.stateDir) dataDir
  );
  stagedDatabaseDump = "${cfg.backupDir}/database/nextcloud.pgcustom";
  prepStepCount = builtins.length clusteredPaths + 1;

  backupPrepScript = pkgs.writeShellScript "alanix-nextcloud-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_host=${lib.escapeShellArg config.services.nextcloud.config.dbhost}
    pg_database=${lib.escapeShellArg config.services.nextcloud.config.dbname}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir" "$(dirname "$staged_dump")"
    chown -R nextcloud:nextcloud "$backup_dir"

    ${lib.concatStringsSep "\n" (builtins.genList
      (index:
        let
          path = builtins.elemAt clusteredPaths index;
        in
        ''
          rsync_prep_step ${toString (index + 1)} ${toString prepStepCount} ${lib.escapeShellArg "staging ${path}"} ${lib.escapeShellArg path} ${lib.escapeShellArg "${cfg.backupDir}${path}"}
        '')
      (builtins.length clusteredPaths))}

    emit_prep_step ${toString prepStepCount} ${toString prepStepCount} ${lib.escapeShellArg "dumping nextcloud database"}
    runuser -u postgres -- env \
      PGHOST="$pg_host" \
      pg_dump \
        --format=custom \
        "$pg_database" > "$staged_dump"

    chown -R nextcloud:nextcloud "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-nextcloud-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_host=${lib.escapeShellArg config.services.nextcloud.config.dbhost}
    pg_user=${lib.escapeShellArg config.services.nextcloud.config.dbuser}
    pg_database=${lib.escapeShellArg config.services.nextcloud.config.dbname}
    restore_dump=""
    cleanup() {
      if [[ -n "$restore_dump" && -e "$restore_dump" ]]; then
        rm -f "$restore_dump"
      fi
      rm -rf "$backup_dir"
    }
    trap cleanup EXIT

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

    chown -R nextcloud:nextcloud ${lib.escapeShellArg cfg.stateDir}
    ${lib.optionalString (dataDir != cfg.stateDir) ''
      chown -R nextcloud:nextcloud ${lib.escapeShellArg dataDir}
    ''}

    # override.config.php is a node-local symlink into the Nix store.
    # Restoring from another node replaces it with a dangling cross-node path.
    # Re-apply tmpfiles to recreate the correct local symlink.
    rm -f ${lib.escapeShellArg "${cfg.stateDir}/config/override.config.php"}
    systemd-tmpfiles --create --prefix=${lib.escapeShellArg "${cfg.stateDir}/config/override.config.php"}

    if [[ -f "$staged_dump" ]]; then
      restore_dump="$(mktemp /var/tmp/alanix-nextcloud-restore-XXXXXX.pgcustom)"
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
        assertion = config.services.nextcloud.database.createLocally;
        message = "Nextcloud cluster mode currently requires a locally managed PostgreSQL database.";
      }
      {
        assertion = config.services.nextcloud.config.dbtype == "pgsql";
        message = "Nextcloud cluster mode currently requires PostgreSQL.";
      }
      {
        assertion = lib.hasPrefix "/" config.services.nextcloud.config.dbhost;
        message = "Nextcloud cluster mode currently requires PostgreSQL on the local host via unix socket.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.stateDir;
        message = "Nextcloud cluster mode requires alanix.nextcloud.stateDir to be an absolute path.";
      }
      {
        assertion = cfg.dataDir == null || lib.hasPrefix "/" cfg.dataDir;
        message = "Nextcloud cluster mode requires alanix.nextcloud.dataDir to be null or an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.backupDir;
        message = "Nextcloud cluster mode requires alanix.nextcloud.backupDir to be an absolute path.";
      }
    ];

    alanix.clusterServices.nextcloud = {
      label = "Nextcloud";
      needsPostgresql = true;
      controller = {
        name = "nextcloud";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits =
          [
            "phpfpm-nextcloud.service"
            "nextcloud-cron.timer"
          ]
          ++ lib.optionals collaboraCfg.enable [ "coolwsd.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits =
        [
          "nextcloud-setup.service"
          "phpfpm-nextcloud.service"
          "nextcloud-cron.timer"
          {
            name = "nextcloud-cron.service";
            start = false;
          }
          "nextcloud-reconcile.service"
        ]
        ++ lib.optionals collaboraCfg.enable [ "coolwsd.service" ];
      exposureUnits =
        [
          "phpfpm-nextcloud.service"
        ]
        ++ lib.optionals collaboraCfg.enable [ "coolwsd.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 nextcloud ${backupRepoUserGroup} - -"
      ];
      webEndpoints =
        [
          {
            id = "nextcloud";
            label = "Nextcloud";
            endpoint = {
              address = cfg.listenAddress;
              port = cfg.port;
              protocol = "http";
            };
            expose = cfg.expose;
          }
        ]
        ++ lib.optionals collaboraCfg.enable [
          {
            id = "nextcloud-collabora";
            label = "Collabora";
            torStateDirName = "nextcloud-collabora";
            endpoint = {
              address = "127.0.0.1";
              port = collaboraCfg.port;
              protocol = "http";
            };
            expose = collaboraCfg.expose;
          }
        ];
    };
    }
    (helpers.mkActiveTargetUnits (
      [
        "nextcloud-setup.service"
        "phpfpm-nextcloud.service"
        "nextcloud-cron.timer"
        {
          name = "nextcloud-cron.service";
          start = false;
        }
        "nextcloud-reconcile.service"
      ]
    ))
    (lib.mkIf collaboraCfg.enable (helpers.mkActiveTargetUnits [ "coolwsd.service" ]))
  ]);
}
