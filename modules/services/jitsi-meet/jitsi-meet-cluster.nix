{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.alanix.jitsi-meet;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable;

  jitsiStateDir = "/var/lib/jitsi-meet";
  prosodyStateDir = config.services.prosody.dataDir;
  stagedJitsiStateDir = "${cfg.backupDir}${jitsiStateDir}";
  stagedProsodyStateDir = "${cfg.backupDir}${prosodyStateDir}";

  daemonUnits = [
    "prosody.service"
    "jicofo.service"
    "jitsi-videobridge2.service"
  ];
  managedUnits = [ "jitsi-meet-init-secrets.service" ] ++ daemonUnits;

  backupPrepScript = pkgs.writeShellScript "alanix-jitsi-meet-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    jitsi_state_dir=${lib.escapeShellArg jitsiStateDir}
    prosody_state_dir=${lib.escapeShellArg prosodyStateDir}
    staged_jitsi_state_dir=${lib.escapeShellArg stagedJitsiStateDir}
    staged_prosody_state_dir=${lib.escapeShellArg stagedProsodyStateDir}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"

    rsync_prep_step 1 2 ${lib.escapeShellArg "staging ${jitsiStateDir}"} "$jitsi_state_dir" "$staged_jitsi_state_dir"
    rsync_prep_step 2 2 ${lib.escapeShellArg "staging ${prosodyStateDir}"} "$prosody_state_dir" "$staged_prosody_state_dir"

    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-jitsi-meet-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    jitsi_state_dir=${lib.escapeShellArg jitsiStateDir}
    prosody_state_dir=${lib.escapeShellArg prosodyStateDir}
    staged_jitsi_state_dir=${lib.escapeShellArg stagedJitsiStateDir}
    staged_prosody_state_dir=${lib.escapeShellArg stagedProsodyStateDir}
    trap 'rm -rf "$backup_dir"' EXIT

    restore_dir() {
      local target="$1"
      local staged_dir="$2"

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

    restore_dir "$jitsi_state_dir" "$staged_jitsi_state_dir"
    restore_dir "$prosody_state_dir" "$staged_prosody_state_dir"

    chown -R root:jitsi-meet "$jitsi_state_dir"
    chmod 0750 "$jitsi_state_dir"
    chown -R prosody:prosody "$prosody_state_dir"
  '';
in
{
  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.hasPrefix "/" prosodyStateDir;
            message = "Jitsi Meet cluster mode requires services.prosody.dataDir to be an absolute path.";
          }
          {
            assertion = lib.hasPrefix "/" cfg.backupDir;
            message = "Jitsi Meet cluster mode requires alanix.jitsi-meet.backupDir to be an absolute path.";
          }
        ];

        alanix.clusterServices.jitsi-meet = {
          label = "Jitsi Meet";
          controller = {
            name = "jitsi-meet";
            label = "Jitsi Meet";
            backupInterval = cfg.cluster.backupInterval;
            maxBackupAge = cfg.cluster.maxBackupAge;
            activeUnits =
              daemonUnits
              ++ lib.optional cfg.turn.enable "coturn.service"
              ++ lib.optional cfg.excalidraw.enable "jitsi-excalidraw.service";
            backupPaths = [ cfg.backupDir ];
            preBackupCommand = [ backupPrepScript ];
            postBackupCommand = [
              "rm"
              "-rf"
              cfg.backupDir
            ];
            postRestoreCommand = [ restoreScript ];
            restoreTarget = "/";
          };
          targetUnits =
            managedUnits
            ++ lib.optional cfg.turn.enable "coturn.service"
            ++ lib.optional cfg.excalidraw.enable "jitsi-excalidraw.service";
          exposureUnits = [
            "nginx.service"
          ]
          ++ daemonUnits
          ++ lib.optional cfg.turn.enable "coturn.service"
          ++ lib.optional cfg.excalidraw.enable "jitsi-excalidraw.service";
          tmpfiles = [
            "d ${cfg.backupDir} 0750 root ${backupRepoUserGroup} - -"
          ];
          webEndpoints = [
            {
              id = "jitsi-meet";
              label = "Jitsi Meet";
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

      (helpers.mkActiveTargetUnits managedUnits)
      (lib.mkIf cfg.turn.enable (helpers.mkActiveTargetUnits [ "coturn.service" ]))
      (lib.mkIf cfg.excalidraw.enable (helpers.mkActiveTargetUnits [ "jitsi-excalidraw.service" ]))
    ]
  );
}
