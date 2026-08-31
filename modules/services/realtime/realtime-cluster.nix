{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.realtime;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;
  prosodyStateDir = config.services.prosody.dataDir;
  stagedRuntimeDir = "${cfg.backupDir}${cfg.stateDir}";
  prosodyGlobalDir = "${prosodyStateDir}/_global";
  stagedProsodyGlobalDir = "${cfg.backupDir}${prosodyGlobalDir}";

  backupPrepScript = pkgs.writeShellScript "alanix-realtime-cluster-backup-runtime" ''
    set -euo pipefail
    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    ${backupPrepProgressHelpers}
    rm -rf "$backup_dir"
    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${cfg.stateDir}"} ${lib.escapeShellArg cfg.stateDir} ${lib.escapeShellArg stagedRuntimeDir}
    rsync_prep_step 2 2 ${lib.escapeShellArg "staging shared Prosody metadata"} ${lib.escapeShellArg prosodyGlobalDir} ${lib.escapeShellArg stagedProsodyGlobalDir}
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-realtime-cluster-restore-runtime" ''
    set -euo pipefail
    backup_dir=${lib.escapeShellArg cfg.backupDir}
    trap 'rm -rf "$backup_dir"' EXIT
    restore_dir() {
      target="$1"; staged="$2"; owner="$3"
      mkdir -p "$target"
      if [ -d "$staged" ]; then
        rsync -a --delete "$staged"/ "$target"/
      fi
      chown -R "$owner" "$target"
    }
    restore_dir ${lib.escapeShellArg cfg.stateDir} ${lib.escapeShellArg stagedRuntimeDir} root:turnserver
    restore_dir ${lib.escapeShellArg prosodyGlobalDir} ${lib.escapeShellArg stagedProsodyGlobalDir} prosody:prosody
  '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      alanix.clusterServices.realtime = {
        label = "XMPP / TURN Runtime";
        controller = {
          name = "realtime";
          label = "XMPP / TURN Runtime";
          backupInterval = cfg.cluster.backupInterval;
          maxBackupAge = cfg.cluster.maxBackupAge;
          activeUnits = [ "alanix-realtime-init.service" "prosody.service" "coturn.service" ];
          backupPaths = [ cfg.backupDir ];
          preBackupCommand = [ backupPrepScript ];
          postBackupCommand = [ "rm" "-rf" cfg.backupDir ];
          postRestoreCommand = [ restoreScript ];
          restoreTarget = "/";
        };
        targetUnits = [ "alanix-realtime-init.service" "prosody.service" "coturn.service" ];
        exposureUnits = [ "prosody.service" "coturn.service" ];
        tmpfiles = [ "d ${cfg.backupDir} 0750 root ${backupRepoUserGroup} - -" ];
      };
    }
    (helpers.mkActiveTargetUnits [ "alanix-realtime-init.service" "prosody.service" "coturn.service" ])
  ]);
}
