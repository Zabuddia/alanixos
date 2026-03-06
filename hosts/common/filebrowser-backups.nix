{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../modules/filebrowser-backups.nix
  ];

  alanix.filebrowserBackups = {
    enable = cluster.services.filebrowser.backups.enable;
    nodeName = hostname;
    activeMarkerPath = config.alanix.filebrowserFailover.activeMarkerPath;
    repositoryBasePath = cluster.services.filebrowser.backups.repositoryBasePath;
    schedule = cluster.services.filebrowser.backups.schedule;
    randomizedDelaySec = cluster.services.filebrowser.backups.randomizedDelaySec;
    pruneOpts = cluster.services.filebrowser.backups.pruneOpts;
    paths = cluster.services.filebrowser.dataPaths;

    passwordSecret = "restic/filebrowser-password";
    sshKeySecret = "filebrowser-failover/sync-private-key";

    nodes = lib.mapAttrs (_: node: {
      inherit (node) priority vpnIP sshTarget;
    }) cluster.nodes;
  };
}
