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
  servicePersistentPaths = service: service.state.persistentPaths;

  restoreSourceNodes =
    builtins.attrNames (lib.filterAttrs (name: _: name != cluster.currentNodeName) cluster.nodes);

  prunePolicyFor =
    service:
    if service.backup ? prunePolicy && service.backup.prunePolicy != null then
      service.backup.prunePolicy
    else
      defaults.prunePolicy;

  timerConfigFor =
    service:
    if service.backup ? timerConfig && service.backup.timerConfig != null then
      service.backup.timerConfig
    else
      defaults.timerConfig;

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
      timerConfig = timerConfigFor service;
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

  restoreScriptPackageFor =
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

      for restore_path in ${lib.concatStringsSep " " (map lib.escapeShellArg (servicePersistentPaths service))}; do
        case "$restore_path" in
          ""|"/"|"/etc"|"/home"|"/nix"|"/root"|"/srv"|"/var")
            echo "Refusing to wipe unsafe restore path: $restore_path" >&2
            exit 1
            ;;
        esac

        if [ -e "$restore_path" ] || [ -L "$restore_path" ]; then
          ${pkgs.coreutils}/bin/rm -rf --one-file-system "$restore_path"
        fi
      done

      RESTIC_PASSWORD_FILE="$PASSWORD_FILE" \
        ${lib.getExe pkgs.restic} -r "$REPOSITORY" restore "$SNAPSHOT" --target /

      ${service.backup.restoreCommand}

      echo "Restored ${serviceName} from $SOURCE_NODE ($SNAPSHOT)."
      echo "Review restored data, then start the service units if appropriate."
    '';

  restoreScriptPackages =
    lib.mapAttrs restoreScriptPackageFor backupServices;

  restoreScriptPaths =
    lib.mapAttrs
      (serviceName: pkg: "${pkg}/bin/alanix-restore-${serviceName}")
      restoreScriptPackages;

  restoreScripts = builtins.attrValues restoreScriptPackages;

  restoreOnActivateScript = pkgs.writeShellScript "alanix-restore-on-activate" ''
    set -euo pipefail

    PASSWORD_FILE=${lib.escapeShellArg resticPasswordPath}

    find_latest_source() {
      local service_name="$1"
      local best_source=""
      local best_epoch="-1"
      local best_time=""

      ${lib.concatMapStringsSep "\n" (
        sourceNode:
        ''
          repo="${incomingBaseDir}/''${service_name}/${sourceNode}"
          if [ -d "$repo" ]; then
            latest_info="$(
              RESTIC_PASSWORD_FILE="$PASSWORD_FILE" \
                ${lib.getExe pkgs.restic} -r "$repo" snapshots --json 2>/dev/null \
                | ${lib.getExe pkgs.jq} -r '
                    if length == 0 then
                      empty
                    else
                      max_by(.time | fromdateiso8601)
                      | [.time, (.time | fromdateiso8601)]
                      | @tsv
                    end
                  ' 2>/dev/null || true
            )"

            if [ -n "$latest_info" ]; then
              latest_time="''${latest_info%%	*}"
              latest_epoch="''${latest_info##*	}"

              if [ "$latest_epoch" -gt "$best_epoch" ]; then
                best_source=${lib.escapeShellArg sourceNode}
                best_epoch="$latest_epoch"
                best_time="$latest_time"
              fi
            fi
          fi
        ''
      ) restoreSourceNodes}

      if [ -n "$best_source" ]; then
        printf '%s\t%s\n' "$best_source" "$best_time"
      fi
    }

    ${lib.concatMapStringsSep "\n" (
      serviceName:
      ''
        latest_source_info="$(find_latest_source ${lib.escapeShellArg serviceName})"
        if [ -n "$latest_source_info" ]; then
          source_node="''${latest_source_info%%	*}"
          snapshot_time="''${latest_source_info##*	}"
          echo "Restoring ${serviceName} from $source_node (latest snapshot at $snapshot_time)..."
          ${restoreScriptPaths.${serviceName}} "$source_node" latest
        else
          echo "No local snapshots available for ${serviceName}; leaving current state in place."
        fi
      ''
    ) (builtins.attrNames backupServices)}
  '';

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

    systemd.services =
      resticServicePathExtensions
      // {
        alanix-restore-on-activate = {
          description = "Restore latest Alanix backups before serving on promotion";
          path = [
            pkgs.coreutils
            pkgs.jq
            pkgs.postgresql
            pkgs.restic
            pkgs.systemd
            pkgs.util-linux
          ];
          serviceConfig = {
            Type = "oneshot";
          };
          script = builtins.readFile restoreOnActivateScript;
        };
    };

    environment.systemPackages = restoreScripts;
  };
}
