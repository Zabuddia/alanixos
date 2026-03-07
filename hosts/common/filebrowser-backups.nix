{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkPrioritizedServiceNodes = import ./mk-prioritized-service-nodes.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceBackups.instances.filebrowser =
    let
      nodes = mkPrioritizedServiceNodes {
        inherit lib cluster;
        priorityOverrides = cluster.services.filebrowser.priorityOverrides;
      };
    in
    {
      enable = cluster.services.filebrowser.backups.enable;
      nodeName = hostname;
      activeMarkerPath = config.alanix.serviceFailover.instances.filebrowser.activeMarkerPath;
      repositoryBasePath = cluster.services.filebrowser.backups.repositoryBasePath;
      schedule = cluster.services.filebrowser.backups.schedule;
      randomizedDelaySec = cluster.services.filebrowser.backups.randomizedDelaySec;
      pruneOpts = cluster.services.filebrowser.backups.pruneOpts;
      paths = cluster.services.filebrowser.dataPaths;

      passwordSecret = cluster.services.filebrowser.backups.passwordSecret;
      sshKeySecret = cluster.syncSshKeySecret;
      nodes = nodes;
    };
}
