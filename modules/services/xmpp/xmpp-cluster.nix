{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.xmpp;
  enabled = cfg.enable && cfg.cluster.enable;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  prosodyStateDir = config.services.prosody.dataDir;
  encodeProsodyHost = domain: lib.replaceStrings [ "." "-" ] [ "%2e" "%2d" ] domain;
  prosodyDomains = [ cfg.domain cfg.conferenceDomain cfg.uploadDomain ];
  prosodyDirs = map (domain: "${prosodyStateDir}/${encodeProsodyHost domain}") prosodyDomains;
  stepCount = builtins.length prosodyDirs;
  backupCommands = lib.concatStringsSep "\n" (lib.imap0 (index: path: ''
    rsync_prep_step ${toString (index + 1)} ${toString stepCount} ${lib.escapeShellArg "staging ${path}"} ${lib.escapeShellArg path} ${lib.escapeShellArg "${cfg.cluster.backupDir}${path}"}
  '') prosodyDirs);
  restoreCommands = lib.concatMapStringsSep "\n" (path: ''
    target=${lib.escapeShellArg path}
    staged=${lib.escapeShellArg "${cfg.cluster.backupDir}${path}"}
    mkdir -p "$target"
    if [ -d "$staged" ]; then
      rsync -a --delete "$staged"/ "$target"/
    fi
    chown -R prosody:prosody "$target"
  '') prosodyDirs;
  backupPrepScript = pkgs.writeShellScript "alanix-xmpp-cluster-backup-runtime" ''
    set -euo pipefail
    backup_dir=${lib.escapeShellArg cfg.cluster.backupDir}
    backup_group=${lib.escapeShellArg backupRepoUserGroup}
    ${backupPrepProgressHelpers}
    rm -rf "$backup_dir"
    ${backupCommands}
    chgrp -R "$backup_group" "$backup_dir"
    chmod -R u=rwX,g=rX,o= "$backup_dir"
  '';
  restoreScript = pkgs.writeShellScript "alanix-xmpp-cluster-restore-runtime" ''
    set -euo pipefail
    backup_dir=${lib.escapeShellArg cfg.cluster.backupDir}
    trap 'rm -rf "$backup_dir"' EXIT
    ${restoreCommands}
  '';
in
{
  config = lib.mkIf enabled {
    alanix.clusterServices.xmpp = {
      label = "Personal XMPP";
      controller = {
        name = "xmpp";
        label = "Personal XMPP";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        activeUnits = [ ];
        backupPaths = [ cfg.cluster.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.cluster.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
        linksByHost = lib.genAttrs config.alanix.cluster.members (_: [
          {
            label = "XMPP";
            transport = "wan";
            url = "xmpp:buddia@${cfg.domain}";
          }
        ]);
      };
      targetUnits = [ ];
      exposureUnits = [ "prosody.service" ];
      tmpfiles = [ "d ${cfg.cluster.backupDir} 0750 prosody ${backupRepoUserGroup} - -" ];
      firewallAllowedTCPPorts = [ cfg.clientPort cfg.serverPort ];
      webEndpoints = [
        {
          id = "xmpp-upload";
          label = "XMPP Uploads";
          endpoint = {
            address = "127.0.0.1";
            port = lib.head config.services.prosody.httpPorts;
            protocol = "http";
          };
          expose = cfg.upload.expose;
        }
      ];
    };
  };
}
