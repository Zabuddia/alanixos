{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  enabledServices = cluster.enabledServices;
  serviceList = builtins.attrValues enabledServices;
  anyTorServices = lib.any (service: service.access.tor.enable) serviceList;
  anyWanServices = lib.any (service: service.access.wan.enable) serviceList;
  anyCloudflareServiceDns = cluster.settings.dns.provider == "cloudflare" && anyWanServices;
  backupEnabledServices =
    lib.filterAttrs (_: service: service.backup.enable) enabledServices;
  backupTimerUnits =
    lib.concatMap
      (serviceName:
        map
          (receiverName: "restic-backups-${serviceName}-to-${receiverName}.timer")
          (builtins.attrNames cluster.backupReceivers))
      (builtins.attrNames backupEnabledServices);

  preRestoreUnits = lib.unique (
    lib.optionals (enabledServices ? immich && enabledServices.immich.database.createLocally) [ "postgresql.service" ]
    ++ lib.optionals (enabledServices ? invidious && enabledServices.invidious.database.createLocally) [ "postgresql.service" ]
  );

  postRestoreUnits = lib.unique (
    lib.optionals (enabledServices ? immich && enabledServices.immich.redis.enable && enabledServices.immich.redis.host == null) [ "redis-immich.service" ]
    ++ lib.optionals (enabledServices ? filebrowser) [ "filebrowser.service" ]
    ++ lib.optionals (enabledServices ? forgejo) [ "forgejo.service" ]
    ++ lib.optionals (enabledServices ? immich) [ "immich-server.service" ]
    ++ lib.optionals (enabledServices ? immich && enabledServices.immich.machineLearning.enable) [ "immich-machine-learning.service" ]
    ++ lib.optionals (enabledServices ? invidious) [ "invidious.service" ]
    ++ lib.optionals (enabledServices ? invidious && enabledServices.invidious.companion.enable) [ "invidious-companion.service" ]
    ++ lib.optionals anyTorServices [
      "alanix-tor-secret-keys.service"
      "tor.service"
    ]
    ++ lib.optionals anyWanServices [ "caddy.service" ]
    ++ lib.optionals anyCloudflareServiceDns [
      "alanix-cloudflare-service-ddns.service"
      "alanix-cloudflare-service-ddns.timer"
    ]
    ++ backupTimerUnits
  );

  stopUnits = lib.reverseList (preRestoreUnits ++ postRestoreUnits);

  roleSyncScript = pkgs.writeShellScript "alanix-role-sync" ''
    set -euo pipefail

    pre_restore_units=(${lib.concatStringsSep " " (map lib.escapeShellArg preRestoreUnits)})
    post_restore_units=(${lib.concatStringsSep " " (map lib.escapeShellArg postRestoreUnits)})
    stop_units=(${lib.concatStringsSep " " (map lib.escapeShellArg stopUnits)})
    state_dir=/var/lib/alanix/role-state
    last_role_file="$state_dir/last-role"
    last_active_node_file="$state_dir/last-active-node"
    failure_file="$state_dir/last-start-failures"
    previous_role=unknown
    previous_active_node=unknown
    failed_units=()

    ${lib.getExe' pkgs.coreutils "mkdir"} -p "$state_dir"
    if [ -r "$last_role_file" ]; then
      IFS= read -r previous_role < "$last_role_file"
    fi
    if [ -r "$last_active_node_file" ]; then
      IFS= read -r previous_active_node < "$last_active_node_file"
    fi
    if [ "$previous_active_node" = "unknown" ] && [ "$previous_role" = "active" ]; then
      previous_active_node=${lib.escapeShellArg cluster.currentNodeName}
    fi

    unit_exists() {
      ${lib.getExe' pkgs.systemd "systemctl"} list-unit-files "$1" >/dev/null 2>&1
    }

    start_unit() {
      local unit="$1"
      if ! unit_exists "$unit"; then
        return 0
      fi

      if ! ${lib.getExe' pkgs.systemd "systemctl"} start "$unit"; then
        echo "alanix-role-sync: failed to start $unit" >&2
        failed_units+=("$unit")
      fi
    }

    stop_unit() {
      local unit="$1"
      if unit_exists "$unit"; then
        ${lib.getExe' pkgs.systemd "systemctl"} stop "$unit" || true
      fi
    }

    if [ ${lib.escapeShellArg cluster.role} = "active" ]; then
      for unit in "''${pre_restore_units[@]}"; do
        start_unit "$unit"
      done

      if [ "$previous_active_node" != ${lib.escapeShellArg cluster.currentNodeName} ] && ${lib.getExe' pkgs.systemd "systemctl"} list-unit-files alanix-restore-on-activate.service >/dev/null 2>&1; then
        if ! ${lib.getExe' pkgs.systemd "systemctl"} start alanix-restore-on-activate.service; then
          echo "alanix-role-sync: failed to run alanix-restore-on-activate.service" >&2
          failed_units+=("alanix-restore-on-activate.service")
          printf '%s\n' "''${failed_units[@]}" > "$failure_file"
          printf '%s\n' ${lib.escapeShellArg cluster.role} > "$last_role_file"
          printf '%s\n' ${lib.escapeShellArg cluster.activeNodeName} > "$last_active_node_file"
          exit 1
        fi
      fi

      for unit in "''${post_restore_units[@]}"; do
        start_unit "$unit"
      done
    else
      for unit in "''${stop_units[@]}"; do
        stop_unit "$unit"
      done
    fi

    printf '%s\n' ${lib.escapeShellArg cluster.role} > "$last_role_file"
    printf '%s\n' ${lib.escapeShellArg cluster.activeNodeName} > "$last_active_node_file"

    if [ "''${#failed_units[@]}" -gt 0 ]; then
      printf '%s\n' "''${failed_units[@]}" > "$failure_file"
      echo "alanix-role-sync: completed with failed units: ''${failed_units[*]}" >&2
    else
      : > "$failure_file"
    fi
  '';

  roleSyncActivationScript = ''
    if [ "''${NIXOS_ACTION:-}" = "dry-activate" ]; then
      echo "would synchronize Alanix role-gated units for role ${cluster.role}"
    else
      ${lib.getExe' pkgs.systemd "systemctl"} daemon-reload
      ${lib.getExe' pkgs.systemd "systemctl"} start alanix-role-sync.service
    fi
  '';

  roleScript = pkgs.writeShellScriptBin "alanix-cluster-role" ''
    set -euo pipefail
    cat <<'EOF'
    node=${cluster.currentNodeName}
    role=${cluster.role}
    active_node=${cluster.activeNodeName}
    domain=${cluster.settings.domain}
    wireguard_ip=${cluster.currentNode.vpnIp}
    EOF
  '';

  servicesScript = pkgs.writeShellScriptBin "alanix-cluster-services" ''
    set -euo pipefail
    cat <<'EOF'
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service: "${name} ${if service.enable then "enabled" else "disabled"}") cluster.services)}
    EOF
  '';
in
{
  system.activationScripts.alanix-role-sync = {
    deps = [
      "etc"
      "users"
    ];
    supportsDryActivation = true;
    text = roleSyncActivationScript;
  };

  systemd.services.alanix-role-sync = {
    description = "Synchronize Alanix role-gated units";
    after = [ "network.target" ];
    wants = [ "network.target" ];
    path = [
      pkgs.coreutils
      pkgs.systemd
    ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = builtins.readFile roleSyncScript;
  };

  environment.systemPackages = [
    roleScript
    servicesScript
  ];
}
