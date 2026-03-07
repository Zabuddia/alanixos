{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceBackups.instances.gitea =
    let
      nodes = lib.mapAttrs (_: node: {
        inherit (node) priority vpnIP sshTarget;
      }) cluster.nodes;
    in
    {
      enable = cluster.services.gitea.backups.enable;
      nodeName = hostname;
      activeMarkerPath = config.alanix.serviceFailover.instances.gitea.activeMarkerPath;
      repositoryBasePath = cluster.services.gitea.backups.repositoryBasePath;
      schedule = cluster.services.gitea.backups.schedule;
      randomizedDelaySec = cluster.services.gitea.backups.randomizedDelaySec;
      pruneOpts = cluster.services.gitea.backups.pruneOpts;
      paths = cluster.services.gitea.dataPaths;

      passwordSecret = cluster.services.gitea.backups.passwordSecret;
      sshKeySecret = cluster.syncSshKeySecret;
      nodes = nodes;
    };
}
