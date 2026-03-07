{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceFailover.instances.filebrowser =
    let
      nodes = lib.mapAttrs (_: node: {
        inherit (node) priority vpnIP sshTarget;
      }) cluster.nodes;
    in
    {
      enable = true;
      nodeName = hostname;
      serviceUnit = "filebrowser.service";
      edgeUnit = null;
      requireServiceEnableOptionPath = [ "alanix" "filebrowser" "enable" ];

      checkInterval = "15s";
      failureThreshold = 4;
      higherUnhealthyThreshold = 20;
      nodes = nodes;

      sync = {
        enable = true;
        interval = "2min";
        paths = cluster.services.filebrowser.dataPaths;
        sshKeySecret = cluster.syncSshKeySecret;
        authorizedPublicKey = cluster.services.filebrowser.syncPublicKey;
        allowedFromCIDR = cluster.wgSubnetCIDR;
        openFirewallOnWg = true;
      };

      dns = {
        enable = true;
        jobName = "filebrowser-failover";
        provider = cluster.dns.provider;
        interval = "2min";
        zone = cluster.domain;
        record = cluster.services.filebrowser.wanAccess.domain;
        tokenSecret = cluster.dns.apiTokenSecret;
        proxied = false;
        ttl = 60;
      };
    };
}
