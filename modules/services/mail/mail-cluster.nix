{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.mail;
  clusterCfg = config.alanix.cluster;
  helpers = import ../../../lib/clusterServiceAdapter.nix { inherit config lib; };
  inherit (helpers) backupPrepProgressHelpers backupRepoUserGroup;
  enabled = cfg.enable && cfg.cluster.enable && cfg.cluster.backupDir != null;

  primaryDomain =
    if cfg.domain != null then
      cfg.domain
    else if cfg.domains != [ ] then
      lib.head cfg.domains
    else
      "localhost";
  redisDataDir = "/var/lib/redis-rspamd";
  rspamdStateDir = "/var/lib/rspamd";
  clusteredPaths = lib.unique (
    [
      cfg.mailDirectory
      cfg.sieveDirectory
      cfg.dkim.keyDirectory
    ]
    ++ lib.optional (cfg.cluster.includeIndexDir && cfg.indexDir != null) cfg.indexDir
    ++ lib.optional cfg.cluster.includeRspamdState rspamdStateDir
    ++ lib.optional (cfg.cluster.includeRedis && config.mailserver.redis.configureLocally) redisDataDir
  );

  linksByHost =
    lib.listToAttrs (
      map (peer: {
        name = peer;
        value = [
          {
            label = "Mail";
            transport = "wan";
            url = "mailto:postmaster@${primaryDomain}";
          }
        ];
      }) clusterCfg.members
    );

  backupPrepScript =
    let
      redisFlushStepCount =
        if cfg.cluster.includeRedis && config.mailserver.redis.configureLocally then 1 else 0;
      prepStepCount = builtins.length clusteredPaths + redisFlushStepCount;
      redisFlushCommand = lib.optionalString (redisFlushStepCount == 1) ''
        emit_prep_step 1 ${toString prepStepCount} ${lib.escapeShellArg "flushing rspamd redis state"}
        if systemctl --quiet is-active redis-rspamd.service; then
          ${config.services.redis.package}/bin/redis-cli -s ${lib.escapeShellArg config.services.redis.servers.rspamd.unixSocket} save >/dev/null
        fi
      '';
      pathRsyncCommands = lib.concatStringsSep "\n" (
        builtins.genList
          (index:
            let
              path = builtins.elemAt clusteredPaths index;
              stepIndex = index + 1 + redisFlushStepCount;
            in
            ''
              rsync_prep_step ${toString stepIndex} ${toString prepStepCount} ${lib.escapeShellArg "staging ${path}"} ${lib.escapeShellArg path} ${lib.escapeShellArg "${cfg.cluster.backupDir}${path}"}
            '')
          (builtins.length clusteredPaths)
      );
    in
    pkgs.writeShellScript "alanix-mail-cluster-backup-runtime" ''
      set -euo pipefail

      backup_dir=${lib.escapeShellArg cfg.cluster.backupDir}
      backup_group=${lib.escapeShellArg backupRepoUserGroup}

      ${backupPrepProgressHelpers}

      rm -rf "$backup_dir"
      mkdir -p "$backup_dir"

      ${redisFlushCommand}
      ${pathRsyncCommands}

      chgrp -R "$backup_group" "$backup_dir"
      chmod -R u=rwX,g=rX,o= "$backup_dir"
    '';

  restoreScript =
    let
      restoreDirCommands = lib.concatMapStringsSep "\n" (
        path:
        let
          ownerGroup =
            if path == cfg.dkim.keyDirectory then
              "${config.services.rspamd.user}:${config.services.rspamd.group}"
            else if path == rspamdStateDir then
              "${config.services.rspamd.user}:${config.services.rspamd.group}"
            else if path == redisDataDir then
              "${config.services.redis.servers.rspamd.user}:${config.services.redis.servers.rspamd.group}"
            else
              "${config.mailserver.vmailUserName}:${config.mailserver.vmailGroupName}";
        in
        ''
          restore_dir ${lib.escapeShellArg path} ${lib.escapeShellArg ownerGroup}
        ''
      ) clusteredPaths;
    in
    pkgs.writeShellScript "alanix-mail-cluster-restore-runtime" ''
      set -euo pipefail

      backup_dir=${lib.escapeShellArg cfg.cluster.backupDir}
      trap 'rm -rf "$backup_dir"' EXIT

      restore_dir() {
        local target="$1"
        local owner_group="$2"
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

        chown -R "$owner_group" "$target"
      }

      ${restoreDirCommands}
    '';
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.mailDirectory;
        message = "Mail cluster mode requires alanix.mail.mailDirectory to be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.sieveDirectory;
        message = "Mail cluster mode requires alanix.mail.sieveDirectory to be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.dkim.keyDirectory;
        message = "Mail cluster mode requires alanix.mail.dkim.keyDirectory to be an absolute path.";
      }
      {
        assertion = cfg.indexDir == null || lib.hasPrefix "/" cfg.indexDir;
        message = "Mail cluster mode requires alanix.mail.indexDir to be null or an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.cluster.backupDir;
        message = "Mail cluster mode requires alanix.mail.cluster.backupDir to be an absolute path.";
      }
    ];

    alanix.clusterServices.mail = {
      label = "Mail";
      controller = {
        name = "mail";
        label = "Mail";
        backupInterval = cfg.cluster.backupInterval;
        maxBackupAge = cfg.cluster.maxBackupAge;
        # Keep kresd out of the cluster active unit set. The local resolver is
        # stateless infrastructure, and resolv.conf points at it on passive
        # nodes too.
        activeUnits =
          [
            "activate-virtual-mail-users.service"
            "redis-rspamd.service"
            "rspamd.service"
            "dovecot.service"
            "postfix.service"
          ]
          ++ lib.optional (cfg.dkim.privateKeySecrets != { }) "alanix-mail-dkim-keys.service"
          ++ lib.optional cfg.dmarcReporting.enable "rspamd-dmarc-reporter.timer"
          ++ lib.optionals cfg.virusScanning [
            "clamav-daemon.socket"
            "clamav-daemon.service"
            "clamav-freshclam.timer"
          ];
        backupPaths = [ cfg.cluster.backupDir ];
        preBackupCommand = [ backupPrepScript ];
        postBackupCommand = [ "rm" "-rf" cfg.cluster.backupDir ];
        postRestoreCommand = [ restoreScript ];
        restoreTarget = "/";
        inherit linksByHost;
      };
      targetUnits =
        [
          "activate-virtual-mail-users.service"
          "redis-rspamd.service"
          "rspamd.service"
          "dovecot.service"
          "postfix.service"
        ]
        ++ lib.optional (cfg.dkim.privateKeySecrets != { }) "alanix-mail-dkim-keys.service"
        ++ lib.optionals cfg.dmarcReporting.enable [
          "rspamd-dmarc-reporter.timer"
          {
            name = "rspamd-dmarc-reporter.service";
            start = false;
          }
        ]
        ++ lib.optionals cfg.virusScanning [
          "clamav-daemon.socket"
          "clamav-daemon.service"
          "clamav-freshclam.timer"
          {
            name = "clamav-freshclam.service";
            start = false;
          }
        ];
      tmpfiles = [
        "d ${cfg.cluster.backupDir} 0750 root ${backupRepoUserGroup} - -"
      ];
    };
    }
    (helpers.mkActiveTargetUnits [
      "activate-virtual-mail-users.service"
      "redis-rspamd.service"
      "rspamd.service"
      "dovecot.service"
      "postfix.service"
    ])
    (lib.mkIf (cfg.dkim.privateKeySecrets != { }) (helpers.mkActiveTargetUnits [ "alanix-mail-dkim-keys.service" ]))
    (lib.mkIf cfg.dmarcReporting.enable (helpers.mkActiveTargetUnits [
      "rspamd-dmarc-reporter.timer"
      {
        name = "rspamd-dmarc-reporter.service";
        start = false;
      }
    ]))
    (lib.mkIf cfg.virusScanning (helpers.mkActiveTargetUnits [
      "clamav-daemon.socket"
      "clamav-daemon.service"
      "clamav-freshclam.timer"
      {
        name = "clamav-freshclam.service";
        start = false;
      }
    ]))
  ]);
}
