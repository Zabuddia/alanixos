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

  checkInterval = "15s";
  failureThreshold = 4;
  higherUnhealthyThreshold = 20;

  sync = {
    enable = true;
    interval = "2min";
    paths = svc.dataPaths;
    sshKeySecret = cluster.syncSshKeySecret;
    authorizedPublicKey = cluster.syncPublicKey;
    allowedFromCIDR = cluster.wgSubnetCIDR;
    openFirewallOnWg = true;
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
