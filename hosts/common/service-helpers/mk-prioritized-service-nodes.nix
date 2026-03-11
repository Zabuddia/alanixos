{ lib, cluster, priorityOverrides ? {} }:
lib.mapAttrs
  (nodeName: node: {
    priority = priorityOverrides.${nodeName} or node.priority;
    inherit (node) clusterAddress clusterDnsName sshTarget;
  })
  cluster.nodes
