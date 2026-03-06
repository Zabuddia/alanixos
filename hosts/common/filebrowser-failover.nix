{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../modules/filebrowser-failover.nix
  ];

  alanix.filebrowserFailover = {
    enable = true;
    nodeName = hostname;
    serviceHealthPort = 443;

    checkInterval = "15s";
    failureThreshold = 4;
    higherUnhealthyThreshold = 20;

    nodes = lib.mapAttrs (_: node: {
      inherit (node) priority vpnIP sshTarget;
    }) cluster.nodes;

    sync = {
      enable = true;
      interval = "2min";
      paths = cluster.services.filebrowser.dataPaths;
      sshKeySecret = "filebrowser-failover/sync-private-key";
      authorizedPublicKey = cluster.services.filebrowser.syncPublicKey;
      allowedFromCIDR = cluster.wgSubnetCIDR;
      openFirewallOnWg = true;
    };

    dns = {
      enable = true;
      provider = cluster.dns.provider;
      interval = "2min";
      zone = cluster.domain;
      record = cluster.services.filebrowser.domain;
      tokenSecret = cluster.dns.apiTokenSecret;
      proxied = false;
      ttl = 60;
    };

  };
}
