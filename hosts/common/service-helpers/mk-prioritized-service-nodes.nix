{ lib, cluster, priorityOverrides ? {} }:
lib.mapAttrs
  (nodeName: node: {
    priority = priorityOverrides.${nodeName} or node.priority;
    inherit (node) vpnIP sshTarget;
  })
  cluster.nodes
