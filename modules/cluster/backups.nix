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

    format_epoch() {
      local epoch="$1"
      if [ -z "$epoch" ] || [ "$epoch" = "0" ]; then
        printf '%s' "-"
      else
        ${pkgs.coreutils}/bin/date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z'
      fi
    }

    format_usec_epoch() {
      local usec="$1"
      if [ -z "$usec" ] || [ "$usec" = "0" ] || [ "$usec" = "n/a" ]; then
        printf '%s' "-"
      else
        format_epoch $((usec / 1000000))
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

    now_epoch="$(${pkgs.coreutils}/bin/date +%s)"
    uptime_seconds="$(${pkgs.coreutils}/bin/cut -d' ' -f1 /proc/uptime)"
    boot_epoch="$(${pkgs.gawk}/bin/awk -v now="$now_epoch" -v uptime="$uptime_seconds" 'BEGIN { printf "%.0f", now - uptime }')"

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
          -p NextElapseUSecMonotonic \
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
        last_run="$(format_usec_epoch "''${timer_props[LastTriggerUSec]:-0}")"
      fi

      next_run="-"
      if [ -n "''${timer_props[NextElapseUSecRealtime]:-}" ] && [ "''${timer_props[NextElapseUSecRealtime]:-0}" != "0" ]; then
        next_run="$(format_usec_epoch "''${timer_props[NextElapseUSecRealtime]}")"
      elif [ -n "''${timer_props[NextElapseUSecMonotonic]:-}" ] && [ "''${timer_props[NextElapseUSecMonotonic]:-0}" != "0" ]; then
        next_run="$(format_epoch $((boot_epoch + timer_props[NextElapseUSecMonotonic] / 1000000)))"
      fi

      printf '%-34s %-10s %-8s %-26s %s\n' "$job" "$result" "$duration" "$last_run" "$next_run"
    done
  '';

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

    environment.systemPackages = restoreScripts ++ [
      runAllBackupsScript
      backupStatusScript
    ];
  };
}
