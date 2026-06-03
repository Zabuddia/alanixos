{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.headscale;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  stagedStateDir = "${cfg.backupDir}${cfg.stateDir}";
  stagedDbPath = "${stagedStateDir}/db.sqlite";
  userNames = builtins.attrNames cfg.users;

  reconcileUsersScript = pkgs.writeShellScript "alanix-headscale-reconcile-users" (
    ''
      set -euo pipefail

      for _ in $(seq 1 60); do
        if headscale users list -o json >/tmp/alanix-headscale-users.json 2>/dev/null; then
          break
        fi
        sleep 1
      done

      if [[ ! -s /tmp/alanix-headscale-users.json ]]; then
        echo "failed to query Headscale users" >&2
        exit 1
      fi
    ''
    + lib.concatMapStringsSep "\n"
      (name:
        let
          user = cfg.users.${name};
          createArgs =
            [ "headscale" "users" "create" name ]
            ++ lib.optionals (user.email != null) [ "--email" user.email ]
            ++ lib.optionals (user.displayName != null) [ "--display-name" user.displayName ];
        in
        ''
          if ! jq -e --arg name ${lib.escapeShellArg name} '.[] | select(.name == $name)' /tmp/alanix-headscale-users.json >/dev/null; then
            ${lib.escapeShellArgs createArgs}
            headscale users list -o json >/tmp/alanix-headscale-users.json
          fi
        '')
      userNames
  );

  backupPrepScript = pkgs.writeShellScript "alanix-headscale-cluster-backup-runtime" ''
    set -euo pipefail

    state_dir=${lib.escapeShellArg cfg.stateDir}
    backup_dir=${lib.escapeShellArg cfg.backupDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_db_path=${lib.escapeShellArg stagedDbPath}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$staged_state_dir"

    emit_prep_step 1 2 ${lib.escapeShellArg "staging Headscale state"}
    if [[ -d "$state_dir" ]]; then
      rsync -a --delete \
        --exclude db.sqlite \
        --exclude db.sqlite-wal \
        --exclude db.sqlite-shm \
        "$state_dir"/ "$staged_state_dir"/
    fi

    emit_prep_step 2 2 ${lib.escapeShellArg "snapshotting Headscale sqlite database"}
    if [[ -f "$state_dir/db.sqlite" ]]; then
      sqlite3 "$state_dir/db.sqlite" ".backup '$staged_db_path'"
    fi

    chown -R headscale:headscale "$backup_dir"
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-headscale-cluster-restore-runtime" ''
    set -euo pipefail

    state_dir=${lib.escapeShellArg cfg.stateDir}
    staged_state_dir=${lib.escapeShellArg stagedStateDir}
    staged_db_path=${lib.escapeShellArg stagedDbPath}
    backup_dir=${lib.escapeShellArg cfg.backupDir}
    trap 'rm -rf "$backup_dir"' EXIT

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

    if [[ -f "$staged_db_path" ]]; then
      install -m0600 -o headscale -g headscale "$staged_db_path" "$state_dir/db.sqlite"
      rm -f "$state_dir/db.sqlite-wal" "$state_dir/db.sqlite-shm"
    fi

    chown -R headscale:headscale "$state_dir"
    chmod -R u=rwX,go= "$state_dir"
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      alanix.clusterServices.headscale = {
        label = "Headscale";
        controller = {
          name = "headscale";
          backupInterval = cfg.cluster.backupInterval;
          maxBackupAge = cfg.cluster.maxBackupAge;
          activeUnits = [ "headscale.service" "alanix-headscale-reconcile-users.service" ];
          backupPaths = [ cfg.backupDir ];
          preBackupCommand = [ backupPrepScript ];
          postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
          postRestoreCommand = [ restoreScript ];
          restoreTarget = "/";
        };
        targetUnits = [ "headscale.service" ];
        exposureUnits = [ "headscale.service" "alanix-headscale-reconcile-users.service" ];
        tmpfiles = [
          "d ${cfg.backupDir} 0750 headscale ${backupRepoUserGroup} - -"
        ];
        webEndpoints = [
          {
            id = "headscale";
            label = "Headscale";
            endpoint = {
              address = cfg.listenAddress;
              port = cfg.port;
              protocol = "http";
            };
            expose = cfg.expose;
          }
        ];
      };

      systemd.services.alanix-headscale-reconcile-users = {
        description = "Reconcile declarative Headscale users";
        after = [ "headscale.service" ];
        wants = [ "headscale.service" ];
        path = [
          config.services.headscale.package
          pkgs.coreutils
          pkgs.jq
        ];
        script = "${reconcileUsersScript}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };
    }
    (helpers.mkActiveTargetUnits [ "headscale.service" "alanix-headscale-reconcile-users.service" ])
  ]);
}
