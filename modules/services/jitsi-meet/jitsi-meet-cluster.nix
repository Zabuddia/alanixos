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
  stagedJitsiStateDir = "${cfg.backupDir}${jitsiStateDir}";
  prosodyStateDir = config.services.prosody.dataDir;
  encodeProsodyHost = domain: lib.replaceStrings [ "." "-" ] [ "%2e" "%2d" ] domain;
  jitsiProsodyDomains = lib.unique (
    (lib.mapAttrsToList (_: hostCfg: hostCfg.domain) (
      lib.filterAttrs (_: hostCfg:
        hostCfg.domain == cfg.hostName || lib.hasSuffix ".${cfg.hostName}" hostCfg.domain
      ) config.services.prosody.virtualHosts
    ))
    ++ map (muc: muc.domain) (
      builtins.filter (muc: muc.domain == cfg.hostName || lib.hasSuffix ".${cfg.hostName}" muc.domain)
        config.services.prosody.muc
    )
  );
  jitsiProsodyDirs = map (domain: "${prosodyStateDir}/${encodeProsodyHost domain}") jitsiProsodyDomains;
  backupStepCount = 1 + builtins.length jitsiProsodyDirs;
  prosodyBackupCommands = lib.concatStringsSep "\n" (lib.imap0 (index: path: ''
    rsync_prep_step ${toString (index + 2)} ${toString backupStepCount} ${lib.escapeShellArg "staging ${path}"} ${lib.escapeShellArg path} ${lib.escapeShellArg "${cfg.backupDir}${path}"}
  '') jitsiProsodyDirs);
  prosodyRestoreCommands = lib.concatMapStringsSep "\n" (path: ''
    restore_dir ${lib.escapeShellArg path} ${lib.escapeShellArg "${cfg.backupDir}${path}"}
  '') jitsiProsodyDirs;

  daemonUnits = [
    "jicofo.service"
    "jitsi-videobridge2.service"
  ];
  managedUnits = [ "jitsi-meet-init-secrets.service" ] ++ daemonUnits;

  backupPrepScript = pkgs.writeShellScript "alanix-jitsi-meet-cluster-backup-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    jitsi_state_dir=${lib.escapeShellArg jitsiStateDir}
    staged_jitsi_state_dir=${lib.escapeShellArg stagedJitsiStateDir}

    ${backupPrepProgressHelpers}

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"

    rsync_prep_step 1 ${toString backupStepCount} ${lib.escapeShellArg "staging ${jitsiStateDir}"} "$jitsi_state_dir" "$staged_jitsi_state_dir"
    ${prosodyBackupCommands}

    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';

  restoreScript = pkgs.writeShellScript "alanix-jitsi-meet-cluster-restore-runtime" ''
    set -euo pipefail

    backup_dir=${lib.escapeShellArg cfg.backupDir}
    jitsi_state_dir=${lib.escapeShellArg jitsiStateDir}
    staged_jitsi_state_dir=${lib.escapeShellArg stagedJitsiStateDir}
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
    ${prosodyRestoreCommands}

    chown -R root:jitsi-meet "$jitsi_state_dir"
    chmod 0750 "$jitsi_state_dir"
    ${lib.concatMapStringsSep "\n" (path: "chown -R prosody:prosody ${lib.escapeShellArg path}") jitsiProsodyDirs}
  '';
in
{
  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        assertions = [
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
            ++ lib.optional cfg.excalidraw.enable "jitsi-excalidraw.service";
          exposureUnits = [
            "nginx.service"
          ]
          ++ daemonUnits
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
      (lib.mkIf cfg.excalidraw.enable (helpers.mkActiveTargetUnits [ "jitsi-excalidraw.service" ]))
    ]
  );
}
