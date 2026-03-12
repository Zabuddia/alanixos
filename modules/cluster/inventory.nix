{ config, lib, hostname, clusterConfig, ... }:
let
  duplicateValues =
    values:
    builtins.attrNames (
      lib.filterAttrs (_: count: count > 1) (
        lib.foldl'
          (acc: value: acc // { "${value}" = (acc.${value} or 0) + 1; })
          { }
          values
      )
    );

  enabledServices = lib.filterAttrs (_: service: service.enable) clusterConfig.services;
  currentNode = clusterConfig.nodes.${hostname} or null;
  activeNodeName = clusterConfig.cluster.activeNode;
  activeNode = clusterConfig.nodes.${activeNodeName} or null;
  backupReceivers =
    lib.filterAttrs
      (name: node: name != hostname && node.receiveBackups)
      clusterConfig.nodes;

  wanDomains =
    lib.concatMap
      (service:
        lib.optional
          (service.access.wan.enable && service.access.wan.domain != null)
          service.access.wan.domain)
      (builtins.attrValues enabledServices);

  wireguardPorts =
    lib.concatMap
      (service:
        lib.optional service.access.wireguard.enable (toString service.access.wireguard.port))
      (builtins.attrValues enabledServices);

  torServiceNames =
    lib.concatMap
      (service:
        lib.optional service.access.tor.enable service.access.tor.serviceName)
      (builtins.attrValues enabledServices);
in
{
  options.alanix.cluster = {
    inventory = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };

    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };

    enabledServices = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };

    currentNodeName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };

    currentNode = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };

    activeNodeName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };

    activeNode = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };

    isActiveNode = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
    };

    role = lib.mkOption {
      type = lib.types.enum [ "active" "standby" ];
      readOnly = true;
    };

    backupReceivers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
    };
  };

  config = {
    assertions = [
      {
        assertion = currentNode != null;
        message = "Host '${hostname}' is not defined in cluster/default.nix.";
      }
      {
        assertion = activeNode != null;
        message = "cluster.activeNode '${activeNodeName}' is not defined in cluster/default.nix.";
      }
      {
        assertion = activeNode == null || activeNode.publicIngress;
        message = "cluster.activeNode must reference a node with publicIngress = true.";
      }
      {
        assertion = duplicateValues (map (node: node.vpnIp) (builtins.attrValues clusterConfig.nodes)) == [ ];
        message =
          "WireGuard vpnIp values must be unique. Duplicates: "
          + lib.concatStringsSep ", " (duplicateValues (map (node: node.vpnIp) (builtins.attrValues clusterConfig.nodes)));
      }
      {
        assertion = duplicateValues (map (node: node.endpointHost) (builtins.attrValues clusterConfig.nodes)) == [ ];
        message =
          "WireGuard endpointHost values must be unique. Duplicates: "
          + lib.concatStringsSep ", " (duplicateValues (map (node: node.endpointHost) (builtins.attrValues clusterConfig.nodes)));
      }
      {
        assertion = duplicateValues wanDomains == [ ];
        message =
          "WAN domains must be unique across enabled services. Duplicates: "
          + lib.concatStringsSep ", " (duplicateValues wanDomains);
      }
      {
        assertion = duplicateValues wireguardPorts == [ ];
        message =
          "WireGuard access ports must be unique across enabled services. Duplicates: "
          + lib.concatStringsSep ", " (duplicateValues wireguardPorts);
      }
      {
        assertion = duplicateValues torServiceNames == [ ];
        message =
          "Tor service names must be unique across enabled services. Duplicates: "
          + lib.concatStringsSep ", " (duplicateValues torServiceNames);
      }
    ];

    alanix.cluster = {
      inventory = clusterConfig;
      settings = clusterConfig.cluster;
      nodes = clusterConfig.nodes;
      services = clusterConfig.services;
      inherit enabledServices currentNode activeNode backupReceivers;
      currentNodeName = hostname;
      inherit activeNodeName;
      isActiveNode = hostname == activeNodeName;
      role = if hostname == activeNodeName then "active" else "standby";
    };
  };
}
