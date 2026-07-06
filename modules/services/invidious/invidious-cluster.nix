{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.invidious;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  invidiousStateDir = "/var/lib/invidious";
  companionStateDir = "/var/lib/invidious-companion";
  stagedInvidiousStateDir = "${cfg.backupDir}${invidiousStateDir}";
  stagedCompanionStateDir = "${cfg.backupDir}${companionStateDir}";
  stagedDatabaseDump = "${cfg.backupDir}/database/invidious.pgcustom";

  backupPrepScript = pkgs.writeShellScript "alanix-invidious-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    state_dir=${lib.escapeShellArg invidiousStateDir}
    companion_dir=${lib.escapeShellArg companionStateDir}
    staged_state_dir=${lib.escapeShellArg stagedInvidiousStateDir}
    staged_companion_dir=${lib.escapeShellArg stagedCompanionStateDir}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_user=${lib.escapeShellArg config.services.invidious.settings.db.user}
    pg_database=${lib.escapeShellArg config.services.invidious.settings.db.dbname}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_state_dir" "$staged_companion_dir" "$(dirname "$staged_dump")"
    chown -R invidious:invidious "$backup_dir"

    rsync_prep_step 1 3 ${lib.escapeShellArg "staging ${invidiousStateDir}"} "$state_dir" "$staged_state_dir"
    rsync_prep_step 2 3 ${lib.escapeShellArg "staging ${companionStateDir}"} "$companion_dir" "$staged_companion_dir"

    emit_prep_step 3 3 ${lib.escapeShellArg "dumping invidious database"}
    runuser -u invidious -- env \
      PGHOST=/run/postgresql \
      PGUSER="$pg_user" \
      PGDATABASE="$pg_database" \
      pg_dump \
        --format=custom \
        --file="$staged_dump" \
        "$pg_database"

    chown -R invidious:invidious "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-invidious-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    state_dir=${lib.escapeShellArg invidiousStateDir}
    companion_dir=${lib.escapeShellArg companionStateDir}
    staged_state_dir=${lib.escapeShellArg stagedInvidiousStateDir}
    staged_companion_dir=${lib.escapeShellArg stagedCompanionStateDir}
    staged_dump=${lib.escapeShellArg stagedDatabaseDump}
    pg_user=${lib.escapeShellArg config.services.invidious.settings.db.user}
    pg_database=${lib.escapeShellArg config.services.invidious.settings.db.dbname}
    trap 'rm -rf "$backup_dir"' EXIT

    if [[ -e "$state_dir" && ! -d "$state_dir" ]]; then
      rm -rf "$state_dir"
    fi
    if [[ -e "$companion_dir" && ! -d "$companion_dir" ]]; then
      rm -rf "$companion_dir"
    fi
    mkdir -p "$state_dir" "$companion_dir"

    if [[ -d "$staged_state_dir" ]]; then
      rsync -a --delete "$staged_state_dir"/ "$state_dir"/
    else
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
    fi

    if [[ -d "$staged_companion_dir" ]]; then
      rsync -a --delete "$staged_companion_dir"/ "$companion_dir"/
    else
      rm -rf "$companion_dir"
      mkdir -p "$companion_dir"
    fi

    chown -R invidious:invidious "$backup_dir" "$state_dir" "$companion_dir"

    if [[ -f "$staged_dump" ]]; then
      runuser -u invidious -- env \
        PGHOST=/run/postgresql \
        PGUSER="$pg_user" \
        PGDATABASE="$pg_database" \
        pg_restore \
          --clean \
          --if-exists \
          --no-owner \
          --no-privileges \
          --exit-on-error \
          --dbname="$pg_database" \
          "$staged_dump"
    fi
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = config.services.invidious.database.createLocally;
        message = "Invidious cluster mode currently requires a locally managed PostgreSQL database.";
      }
      {
        assertion = config.services.invidious.database.host == null;
        message = "Invidious cluster mode currently requires PostgreSQL on the local host.";
      }
    ];

    alanix.clusterServices.invidious = {
      label = "Invidious";
      needsPostgresql = true;
      controller = {
        name = "invidious";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits =
          [ "invidious.service" ]
          ++ lib.optionals cfg.companion.enable [ "invidious-companion.service" ];
        backupPaths = [ cfg.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
      };
      targetUnits =
        [ "invidious.service" ]
        ++ lib.optionals cfg.companion.enable [ "invidious-companion.service" ];
      exposureUnits =
        [ "invidious.service" ]
        ++ lib.optionals cfg.companion.enable [ "invidious-companion.service" ];
      tmpfiles = [
        "d ${cfg.backupDir} 0750 invidious ${backupRepoUserGroup} - -"
      ];
      webEndpoints = [
        {
          id = "invidious";
          label = "Invidious";
          endpoint = {
            address = cfg.listenAddress;
            port = cfg.port;
            protocol = "http";
          };
          extraCaddyConfig = lib.optionalString cfg.companion.enable ''
            handle ${cfg.companion.basePath}* {
              reverse_proxy http://${cfg.companion.listenAddress}:${toString cfg.companion.port}
            }

            handle {
              reverse_proxy http://${cfg.listenAddress}:${toString cfg.port}
            }
          '';
          disableDefaultCaddyReverseProxy = cfg.companion.enable;
          expose = cfg.expose;
        }
      ];
    };
    }
    (helpers.mkActiveTargetUnits [ "invidious.service" ])
    (lib.mkIf cfg.companion.enable (helpers.mkActiveTargetUnits [ "invidious-companion.service" ]))
  ]);
}
