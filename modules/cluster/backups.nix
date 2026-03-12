{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  defaults = cluster.settings.backupDefaults;
  incomingBaseDir = defaults.incomingBaseDir;
  knownHostsDir = "/var/lib/alanix/backups";
  backupUid = 44990;
  backupGid = 44990;
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

  sftpCommandFor =
    receiverNode:
    "sftp.command='ssh -i ${sshPrivateKeyPath} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${knownHostsDir}/known_hosts ${defaults.sshUser}@${receiverNode.vpnIp} -s sftp'";

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
      extraOptions = [ (sftpCommandFor receiverNode) ];
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

  backupIdentityMigrationScript = ''
    if [ "''${NIXOS_ACTION:-}" = "dry-activate" ]; then
      echo "would migrate cluster-backup UID/GID to ${toString backupUid}:${toString backupGid} if needed"
    elif getent group cluster-backup >/dev/null 2>&1 && getent passwd cluster-backup >/dev/null 2>&1; then
      terminate_cluster_backup_processes() {
        local uid="$1"

        ${pkgs.systemd}/bin/systemctl stop "user@''${uid}.service" "user-runtime-dir@''${uid}.service" >/dev/null 2>&1 || true
        ${pkgs.systemd}/bin/loginctl terminate-user "$uid" >/dev/null 2>&1 || true
        ${pkgs.procps}/bin/pkill -TERM -u "$uid" >/dev/null 2>&1 || true

        for _ in $(seq 1 20); do
          if ! ${pkgs.procps}/bin/pgrep -u "$uid" >/dev/null 2>&1; then
            return 0
          fi
          sleep 0.5
        done

        ${pkgs.procps}/bin/pkill -KILL -u "$uid" >/dev/null 2>&1 || true

        for _ in $(seq 1 10); do
          if ! ${pkgs.procps}/bin/pgrep -u "$uid" >/dev/null 2>&1; then
            return 0
          fi
          sleep 0.5
        done

        return 1
      }

      current_gid="$(getent group cluster-backup | cut -d: -f3)"
      current_uid="$(getent passwd cluster-backup | cut -d: -f3)"
      target_group_owner="$(getent group ${toString backupGid} | cut -d: -f1 || true)"
      target_user_owner="$(getent passwd ${toString backupUid} | cut -d: -f1 || true)"

      if [ -n "$target_group_owner" ] && [ "$target_group_owner" != "cluster-backup" ]; then
        echo "alanix-backups: GID ${toString backupGid} is already owned by $target_group_owner" >&2
        exit 1
      fi

      if [ -n "$target_user_owner" ] && [ "$target_user_owner" != "cluster-backup" ]; then
        echo "alanix-backups: UID ${toString backupUid} is already owned by $target_user_owner" >&2
        exit 1
      fi

      if [ "$current_gid" != "${toString backupGid}" ]; then
        ${pkgs.shadow}/bin/groupmod -g ${toString backupGid} cluster-backup
      fi

      if [ "$current_uid" != "${toString backupUid}" ] || [ "$(id -g cluster-backup)" != "${toString backupGid}" ]; then
        if ${pkgs.procps}/bin/pgrep -u "$current_uid" >/dev/null 2>&1; then
          echo "alanix-backups: terminating live cluster-backup processes for UID migration" >&2
          terminate_cluster_backup_processes "$current_uid"
        fi

        ${pkgs.shadow}/bin/usermod -u ${toString backupUid} -g ${toString backupGid} cluster-backup
      fi
    fi
  '';

  runAllBackupsScript = pkgs.writeShellScriptBin "alanix-run-backups-now" ''
    set -euo pipefail

    mapfile -t units < <(
      ${pkgs.systemd}/bin/systemctl list-unit-files 'restic-backups-*.service' --no-legend --no-pager \
        | ${pkgs.gawk}/bin/awk '{print $1}' \
        | ${pkgs.gnugrep}/bin/grep '^restic-backups-.*\.service$' \
        | ${pkgs.coreutils}/bin/sort
    )

    if [ "''${#units[@]}" -eq 0 ]; then
      echo "No backup service units are installed on this node."
      exit 0
    fi

    overall_start="$(${pkgs.coreutils}/bin/date +%s)"
    failed_units=()

    for unit in "''${units[@]}"; do
      start="$(${pkgs.coreutils}/bin/date +%s)"
      echo "Starting $unit ..."
      if ! ${pkgs.systemd}/bin/systemctl start "$unit"; then
        end="$(${pkgs.coreutils}/bin/date +%s)"
        duration=$((end - start))
        failed_units+=("$unit")
        echo "FAILED  $unit (''${duration}s)" >&2
        ${pkgs.systemd}/bin/journalctl -u "$unit" -n 40 --no-pager >&2 || true
        continue
      fi
      end="$(${pkgs.coreutils}/bin/date +%s)"
      duration=$((end - start))

      result="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=Result --value 2>/dev/null || true)"
      status="$(${pkgs.systemd}/bin/systemctl is-failed "$unit" 2>/dev/null || true)"

      if [ "$result" != "success" ] && [ "$status" = "failed" ]; then
        failed_units+=("$unit")
        echo "FAILED  $unit (''${duration}s)" >&2
        ${pkgs.systemd}/bin/journalctl -u "$unit" -n 40 --no-pager >&2 || true
        continue
      fi

      echo "OK      $unit (''${duration}s)"
    done

    overall_end="$(${pkgs.coreutils}/bin/date +%s)"
    if [ "''${#failed_units[@]}" -gt 0 ]; then
      echo "Completed with failures in $((overall_end - overall_start))s: ''${failed_units[*]}" >&2
      exit 1
    fi

    echo "Completed all backups in $((overall_end - overall_start))s"
  '';

  backupStatusScript = pkgs.writeShellScriptBin "alanix-backup-status" ''
    set -euo pipefail

    format_value() {
      local value="$1"
      if [ -z "$value" ] || [ "$value" = "n/a" ] || [ "$value" = "0" ]; then
        printf '%s' "-"
      else
        printf '%s' "$value"
      fi
    }

    format_duration() {
      local start_us="$1"
      local end_us="$2"

      if [ -z "$start_us" ] || [ -z "$end_us" ] || [ "$start_us" = "0" ] || [ "$end_us" = "0" ] || [ "$end_us" -lt "$start_us" ]; then
        printf '%s' "-"
        return 0
      fi

      printf '%ss' $(( (end_us - start_us) / 1000000 ))
    }

    mapfile -t units < <(
      ${pkgs.systemd}/bin/systemctl list-unit-files 'restic-backups-*.service' --no-legend --no-pager \
        | ${pkgs.gawk}/bin/awk '{print $1}' \
        | ${pkgs.gnugrep}/bin/grep '^restic-backups-.*\.service$' \
        | ${pkgs.coreutils}/bin/sort
    )

    if [ "''${#units[@]}" -eq 0 ]; then
      echo "No backup service units are installed on this node."
      exit 0
    fi

    printf '%-34s %-10s %-8s %-26s %s\n' "job" "result" "duration" "last-run" "next-run"
    printf '%-34s %-10s %-8s %-26s %s\n' "---" "------" "--------" "--------" "--------"

    for unit in "''${units[@]}"; do
      timer="''${unit%.service}.timer"
      job="''${unit#restic-backups-}"
      job="''${job%.service}"

      unset svc_props timer_props
      declare -A svc_props=()
      declare -A timer_props=()

      while IFS='=' read -r key value; do
        svc_props["$key"]="$value"
      done < <(
        ${pkgs.systemd}/bin/systemctl show "$unit" \
          -p ActiveState \
          -p Result \
          -p ExecMainStartTimestamp \
          -p ExecMainExitTimestamp \
          -p ExecMainStartTimestampMonotonic \
          -p ExecMainExitTimestampMonotonic \
          --no-pager
      )

      while IFS='=' read -r key value; do
        timer_props["$key"]="$value"
      done < <(
        ${pkgs.systemd}/bin/systemctl show "$timer" \
          -p ActiveState \
          -p NextElapseUSecRealtime \
          -p LastTriggerUSec \
          --no-pager 2>/dev/null || true
      )

      result="''${svc_props[Result]:-}"
      active_state="''${svc_props[ActiveState]:-unknown}"
      timer_active_state="''${timer_props[ActiveState]:-inactive}"
      if [ -z "$result" ] || [ "$result" = "success" ]; then
        if [ "$timer_active_state" = "active" ] && [ "$active_state" = "inactive" ]; then
          result="scheduled"
        else
          result="$active_state"
        fi
      fi

      duration="$(
        format_duration \
          "''${svc_props[ExecMainStartTimestampMonotonic]:-0}" \
          "''${svc_props[ExecMainExitTimestampMonotonic]:-0}"
      )"

      last_run="$(format_value "''${svc_props[ExecMainExitTimestamp]:-}")"
      if [ "$last_run" = "-" ]; then
        last_run="$(format_value "''${timer_props[LastTriggerUSec]:-}")"
      fi

      next_run="$(format_value "''${timer_props[NextElapseUSecRealtime]:-}")"

      printf '%-34s %-10s %-8s %-26s %s\n' "$job" "$result" "$duration" "$last_run" "$next_run"
    done
  '';

  restoreOnActivateScript = pkgs.writeShellScript "alanix-restore-on-activate" ''
    set -euo pipefail

    PASSWORD_FILE=${lib.escapeShellArg resticPasswordPath}
    STATE_DIR=/var/lib/alanix/role-state
    LAST_RESTORE_FILE="$STATE_DIR/last-restore"

    ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"
    : > "$LAST_RESTORE_FILE"

    find_latest_source() {
      local service_name="$1"
      local best_source=""
      local best_epoch="-1"
      local best_time=""
      local inspect_error=0

      ${lib.concatMapStringsSep "\n" (
        sourceNode:
        ''
          repo="${incomingBaseDir}/''${service_name}/${sourceNode}"
          if [ -d "$repo" ]; then
            latest_json="$(RESTIC_PASSWORD_FILE="$PASSWORD_FILE" ${lib.getExe pkgs.restic} -r "$repo" snapshots --latest 1 --json 2>/dev/null || true)"
            if [ -z "$latest_json" ]; then
              echo "Failed to inspect local backup repository for ''${service_name} from ${sourceNode}" >&2
              inspect_error=1
              continue
            fi

            latest_time="$(printf '%s\n' "$latest_json" | ${lib.getExe pkgs.jq} -r 'if length == 0 then empty else .[0].time end' 2>/dev/null || true)"
            if [ -z "$latest_time" ]; then
              continue
            fi

            latest_epoch="$(${lib.getExe' pkgs.coreutils "date"} -d "$latest_time" +%s 2>/dev/null || true)"
            if [ -z "$latest_epoch" ]; then
              echo "Unable to parse snapshot time '$latest_time' for ''${service_name} from ${sourceNode}" >&2
              inspect_error=1
              continue
            fi

            if [ "$latest_epoch" -gt "$best_epoch" ]; then
              best_source=${lib.escapeShellArg sourceNode}
              best_epoch="$latest_epoch"
              best_time="$latest_time"
            fi
          fi
        ''
      ) restoreSourceNodes}

      if [ "$inspect_error" -ne 0 ] && [ -z "$best_source" ]; then
        return 1
      fi

      if [ -n "$best_source" ]; then
        printf '%s\t%s\n' "$best_source" "$best_time"
      fi
    }

    ${lib.concatMapStringsSep "\n" (
      serviceName:
      ''
        if ! latest_source_info="$(find_latest_source ${lib.escapeShellArg serviceName})"; then
          echo "Failed to inspect local snapshots for ${serviceName}." >&2
          exit 1
        fi

        if [ -n "$latest_source_info" ]; then
          source_node="''${latest_source_info%%	*}"
          snapshot_time="''${latest_source_info##*	}"
          echo "Restoring ${serviceName} from $source_node (latest snapshot at $snapshot_time)..."
          ${restoreScriptPaths.${serviceName}} "$source_node" latest
          printf '%s\t%s\t%s\n' ${lib.escapeShellArg serviceName} "$source_node" "$snapshot_time" >> "$LAST_RESTORE_FILE"
        else
          echo "No local snapshots available for ${serviceName}; leaving current state in place."
          printf '%s\t%s\t%s\n' ${lib.escapeShellArg serviceName} "-" "-" >> "$LAST_RESTORE_FILE"
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
    system.activationScripts.alanix-cluster-backup-id-migration = {
      supportsDryActivation = true;
      text = backupIdentityMigrationScript;
    };

    system.activationScripts.users.deps = lib.mkBefore [ "alanix-cluster-backup-id-migration" ];

    users.groups.cluster-backup = {
      gid = backupGid;
    };
    users.users.cluster-backup = {
      isSystemUser = true;
      uid = backupUid;
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

    system.activationScripts.alanix-backup-repo-ownership = {
      deps = [ "users" ];
      supportsDryActivation = true;
      text = ''
        if [ "''${NIXOS_ACTION:-}" = "dry-activate" ]; then
          echo "would repair Alanix backup repository ownership under ${incomingBaseDir}"
        elif [ -d ${lib.escapeShellArg incomingBaseDir} ]; then
          chown -R cluster-backup:cluster-backup ${lib.escapeShellArg incomingBaseDir}
        fi
      '';
    };

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

    environment.systemPackages = restoreScripts ++ [
      runAllBackupsScript
      backupStatusScript
    ];
  };
}
