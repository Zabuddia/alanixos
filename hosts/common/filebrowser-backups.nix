{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceBackups.instances.filebrowser =
    let
      nodes = lib.mapAttrs (_: node: {
        inherit (node) priority vpnIP sshTarget;
      }) cluster.nodes;
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
