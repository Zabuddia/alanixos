{ config, lib, hostname, cluster, serviceName }:
let
  mkPrioritizedServiceNodes = import ./mk-prioritized-service-nodes.nix;
  svc = builtins.getAttr serviceName cluster.services;
  nodes = mkPrioritizedServiceNodes {
    inherit lib cluster;
    priorityOverrides = svc.priorityOverrides;
  };
in
{
  enable = svc.backups.enable;
  nodeName = hostname;
  activeMarkerPath = config.alanix.serviceFailover.instances.${serviceName}.activeMarkerPath;
  repositoryBasePath = svc.backups.repositoryBasePath;
  schedule = svc.backups.schedule;
  randomizedDelaySec = svc.backups.randomizedDelaySec;
  pruneOpts = svc.backups.pruneOpts;
  paths = svc.dataPaths;

  passwordSecret = svc.backups.passwordSecret;
  sshKeySecret = cluster.syncSshKeySecret;
  inherit nodes;
}
