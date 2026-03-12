{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  enabledServices = cluster.enabledServices;
  serviceList = builtins.attrValues enabledServices;
  anyTorServices = lib.any (service: service.access.tor.enable) serviceList;
  anyWanServices = lib.any (service: service.access.wan.enable) serviceList;
  backupEnabledServices =
    lib.filterAttrs (_: service: service.backup.enable) enabledServices;
  backupTimerUnits =
    lib.concatMap
      (serviceName:
        map
          (receiverName: "restic-backups-${serviceName}-to-${receiverName}.timer")
          (builtins.attrNames cluster.backupReceivers))
      (builtins.attrNames backupEnabledServices);

  startUnits = lib.unique (
    lib.optionals (enabledServices ? immich && enabledServices.immich.database.createLocally) [ "postgresql.service" ]
    ++ lib.optionals (enabledServices ? invidious && enabledServices.invidious.database.createLocally) [ "postgresql.service" ]
    ++ lib.optionals (enabledServices ? immich && enabledServices.immich.redis.enable && enabledServices.immich.redis.host == null) [ "redis-immich.service" ]
    ++ lib.optionals anyTorServices [
      "alanix-tor-secret-keys.service"
      "tor.service"
    ]
    ++ lib.optionals anyWanServices [ "caddy.service" ]
    ++ lib.optionals (enabledServices ? filebrowser) [ "filebrowser.service" ]
    ++ lib.optionals (enabledServices ? forgejo) [ "forgejo.service" ]
    ++ lib.optionals (enabledServices ? immich) [ "immich-server.service" ]
    ++ lib.optionals (enabledServices ? immich && enabledServices.immich.machineLearning.enable) [ "immich-machine-learning.service" ]
    ++ lib.optionals (enabledServices ? invidious) [ "invidious.service" ]
    ++ lib.optionals (enabledServices ? invidious && enabledServices.invidious.companion.enable) [ "invidious-companion.service" ]
    ++ backupTimerUnits
  );

  stopUnits = lib.reverseList startUnits;

  roleSyncScript = pkgs.writeShellScript "alanix-role-sync" ''
    set -euo pipefail

    start_units=(${lib.concatStringsSep " " (map lib.escapeShellArg startUnits)})
    stop_units=(${lib.concatStringsSep " " (map lib.escapeShellArg stopUnits)})

    if [ ${lib.escapeShellArg cluster.role} = "active" ]; then
      for unit in "''${start_units[@]}"; do
        ${lib.getExe' pkgs.systemd "systemctl"} start "$unit"
      done
    else
      for unit in "''${stop_units[@]}"; do
        ${lib.getExe' pkgs.systemd "systemctl"} stop "$unit" || true
      done
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
  environment.etc."alanix/role.json".text = builtins.toJSON {
    node = cluster.currentNodeName;
    role = cluster.role;
    activeNode = cluster.activeNodeName;
    currentNode = cluster.currentNode;
  };

  environment.etc."alanix/inventory.json".text = builtins.toJSON cluster.inventory;

  systemd.services.alanix-role-sync = {
    description = "Synchronize Alanix role-gated units";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    wants = [ "network.target" ];
    path = [ pkgs.systemd ];
    restartTriggers = [
      (builtins.toJSON {
        role = cluster.role;
        activeNode = cluster.activeNodeName;
        units = startUnits;
      })
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = builtins.readFile roleSyncScript;
  };

  environment.systemPackages = [
    roleScript
    servicesScript
  ];
}
