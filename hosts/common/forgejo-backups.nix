{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkPrioritizedServiceNodes = import ./mk-prioritized-service-nodes.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceBackups.instances.forgejo =
    let
      nodes = mkPrioritizedServiceNodes {
        inherit lib cluster;
        priorityOverrides = cluster.services.forgejo.priorityOverrides;
      };
    in
    {
      enable = cluster.services.forgejo.backups.enable;
      nodeName = hostname;
      activeMarkerPath = config.alanix.serviceFailover.instances.forgejo.activeMarkerPath;
      repositoryBasePath = cluster.services.forgejo.backups.repositoryBasePath;
      schedule = cluster.services.forgejo.backups.schedule;
      randomizedDelaySec = cluster.services.forgejo.backups.randomizedDelaySec;
      pruneOpts = cluster.services.forgejo.backups.pruneOpts;
      paths = cluster.services.forgejo.dataPaths;

      passwordSecret = cluster.services.forgejo.backups.passwordSecret;
      sshKeySecret = cluster.syncSshKeySecret;
      nodes = nodes;
    };
}
