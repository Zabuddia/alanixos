{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  defaults = cluster.settings.backupDefaults;
  incomingBaseDir = defaults.incomingBaseDir;
  knownHostsDir = "/var/lib/alanix/backups";
  sshPrivateKeyPath = config.sops.secrets.${defaults.sshPrivateKeySecret}.path;
  resticPasswordPath = config.sops.secrets.${defaults.passwordSecret}.path;

  backupServices =
    lib.filterAttrs (_: service: service.enable && service.backup.enable) cluster.services;

  receiverNodes =
    lib.filterAttrs (_: node: node.receiveBackups) cluster.nodes;

  outgoingReceivers =
    lib.filterAttrs
      (name: _: name != cluster.currentNodeName)
      cluster.backupReceivers;

  sftpCommand =
    "sftp.command='ssh -i ${sshPrivateKeyPath} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${knownHostsDir}/known_hosts -s sftp'";

  serviceUnits = {
    filebrowser = [ "filebrowser.service" ];
    forgejo = [ "forgejo.service" ];
    immich = [
      "immich-server.service"
      "immich-machine-learning.service"
    ];
    invidious = [
      "invidious.service"
      "invidious-companion.service"
    ];
  };

  serviceBackupPaths = service: service.backup.paths;

  prunePolicyFor =
    service:
    if service.backup ? prunePolicy && service.backup.prunePolicy != null then
      service.backup.prunePolicy
    else
      defaults.prunePolicy;

  scheduleFor =
    service:
    if service.backup ? schedule then
      service.backup.schedule
    else
      defaults.schedule;

  mkBackupJob = serviceName: service: receiverName: receiverNode: {
    name = "${serviceName}-to-${receiverName}";
    value = {
      initialize = true;
      repository =
        "sftp:${defaults.sshUser}@${receiverNode.vpnIp}:${incomingBaseDir}/${serviceName}/${cluster.currentNodeName}";
      passwordFile = resticPasswordPath;
      paths = serviceBackupPaths service;
      extraOptions = [ sftpCommand ];
      pruneOpts = prunePolicyFor service;
      timerConfig = {
        OnCalendar = scheduleFor service;
        RandomizedDelaySec = defaults.randomizedDelaySec;
        Persistent = true;
      };
      backupPrepareCommand =
        if service.backup ? prepareCommand then
          service.backup.prepareCommand
        else
          null;
    };
  };

  outgoingJobs =
    if cluster.isActiveNode then
      builtins.listToAttrs (
        lib.concatMap
          (serviceName:
            let
              service = backupServices.${serviceName};
            in
            lib.mapAttrsToList
              (receiverName: receiverNode: mkBackupJob serviceName service receiverName receiverNode)
              outgoingReceivers)
          (builtins.attrNames backupServices)
      )
    else
      { };

  outgoingJobNames = builtins.attrNames outgoingJobs;

  incomingTmpfiles =
    [
      "d ${knownHostsDir} 0700 root root - -"
      "d ${incomingBaseDir} 0750 cluster-backup cluster-backup - -"
    ]
    ++ lib.concatMap
      (serviceName:
        let
          receivers =
            lib.mapAttrsToList
              (sourceName: _: "d ${incomingBaseDir}/${serviceName}/${sourceName} 0750 cluster-backup cluster-backup - -")
              (lib.filterAttrs (name: _: name != cluster.currentNodeName) cluster.nodes);
        in
        [ "d ${incomingBaseDir}/${serviceName} 0750 cluster-backup cluster-backup - -" ] ++ receivers)
      (builtins.attrNames backupServices);

  incomingAuthorizedSources =
    lib.concatStringsSep "," (map (node: node.vpnIp) (builtins.attrValues receiverNodes));

  restoreScriptFor =
    serviceName: service:
    pkgs.writeShellScriptBin "alanix-restore-${serviceName}" ''
      set -euo pipefail

      if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "Usage: alanix-restore-${serviceName} <source-node> [snapshot]" >&2
        exit 1
      fi

      SOURCE_NODE="$1"
      SNAPSHOT="''${2:-latest}"
      REPOSITORY="${incomingBaseDir}/${serviceName}/$SOURCE_NODE"
      PASSWORD_FILE=${lib.escapeShellArg resticPasswordPath}

      if [ ! -d "$REPOSITORY" ]; then
        echo "No local repository for ${serviceName} from source node '$SOURCE_NODE' at $REPOSITORY" >&2
        exit 1
      fi

      for unit in ${lib.concatStringsSep " " (map lib.escapeShellArg serviceUnits.${serviceName})}; do
        if ${pkgs.systemd}/bin/systemctl list-unit-files "$unit" >/dev/null 2>&1; then
          ${pkgs.systemd}/bin/systemctl stop "$unit" || true
        fi
      done

      RESTIC_PASSWORD_FILE="$PASSWORD_FILE" \
        ${lib.getExe pkgs.restic} -r "$REPOSITORY" restore "$SNAPSHOT" --target /

      ${service.backup.restoreCommand}

      echo "Restored ${serviceName} from $SOURCE_NODE ($SNAPSHOT)."
      echo "Review restored data, then start the service units if appropriate."
    '';

  restoreScripts =
    map
      (serviceName: restoreScriptFor serviceName backupServices.${serviceName})
      (builtins.attrNames backupServices);

  resticServicePathExtensions =
    builtins.listToAttrs (
      map
        (jobName: {
          name = "restic-backups-${jobName}";
          value.path = [
            pkgs.coreutils
            pkgs.postgresql
            pkgs.util-linux
          ];
        })
        outgoingJobNames
    );
in
{
  config = {
    users.groups.cluster-backup = { };
    users.users.cluster-backup = {
      isSystemUser = true;
      group = "cluster-backup";
      home = incomingBaseDir;
      createHome = false;
      shell = "/run/current-system/sw/bin/nologin";
      openssh.authorizedKeys.keys = [
        "from=\"${incomingAuthorizedSources}\",restrict ${defaults.sshPublicKey}"
      ];
    };

    services.openssh.extraConfig = lib.mkAfter ''
      Match User cluster-backup
        ForceCommand internal-sftp
        PasswordAuthentication no
        PermitTTY no
        X11Forwarding no
        AllowTcpForwarding no
        PermitTunnel no
    '';

    systemd.tmpfiles.rules = incomingTmpfiles;

    services.restic.backups = outgoingJobs;

    systemd.services = resticServicePathExtensions;

    environment.systemPackages = restoreScripts;
  };
}
