{ config, lib, hostname, cluster, serviceName, serviceUnit, edgeUnit ? null, activeDetectionFallbackPort ? 22, enable }:
let
  mkPrioritizedServiceNodes = import ./mk-prioritized-service-nodes.nix;
  svc = builtins.getAttr serviceName cluster.services;
  nodes = mkPrioritizedServiceNodes {
    inherit lib cluster;
    priorityOverrides = svc.priorityOverrides;
  };
in
{
  inherit enable nodes;
  nodeName = hostname;
  inherit serviceUnit edgeUnit;
  inherit activeDetectionFallbackPort;
  requireServiceEnableOptionPath = [ "alanix" serviceName "enable" ];

  checkInterval = "10s";
  failureThreshold = 3;
  campaignDelayStepSeconds = 20;
  leaderInfoStaleSeconds = 45;
  lockTtlSeconds = 30;

  sync = {
    enable = true;
    interval = "2min";
    paths = svc.dataPaths;
    sshKeySecret = cluster.syncSshKeySecret;
    authorizedPublicKey = cluster.syncPublicKey;
    authorizedSourcePatterns = lib.unique (map (node: node.clusterAddress) (builtins.attrValues nodes));
    firewallInterface = cluster.transport.interface;
    openFirewallOnClusterInterface = true;
  };

  dns = {
    enable = true;
    jobName = "${serviceName}-failover";
    provider = cluster.dns.provider;
    interval = "2min";
    zone = cluster.domain;
    record = svc.wanAccess.domain;
    tokenSecret = cluster.dns.apiTokenSecret;
    proxied = false;
    ttl = 60;
  };
}
