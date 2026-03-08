{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkPrioritizedServiceNodes = import ./mk-prioritized-service-nodes.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceBackups.instances.vaultwarden =
    let
      nodes = mkPrioritizedServiceNodes {
        inherit lib cluster;
        priorityOverrides = cluster.services.vaultwarden.priorityOverrides;
      };
    in
    {
      enable = cluster.services.vaultwarden.backups.enable;
      nodeName = hostname;
      activeMarkerPath = config.alanix.serviceFailover.instances.vaultwarden.activeMarkerPath;
      repositoryBasePath = cluster.services.vaultwarden.backups.repositoryBasePath;
      schedule = cluster.services.vaultwarden.backups.schedule;
      randomizedDelaySec = cluster.services.vaultwarden.backups.randomizedDelaySec;
      pruneOpts = cluster.services.vaultwarden.backups.pruneOpts;
      paths = cluster.services.vaultwarden.dataPaths;

      passwordSecret = cluster.services.vaultwarden.backups.passwordSecret;
      sshKeySecret = cluster.syncSshKeySecret;
      nodes = nodes;
    };
}
