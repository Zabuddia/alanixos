{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceFailover.instances.gitea =
    let
      nodes = lib.mapAttrs (_: node: {
        inherit (node) priority vpnIP sshTarget;
      }) cluster.nodes;
    in
    {
      enable = cluster.services.gitea.enable;
      nodeName = hostname;
      serviceUnit = "gitea.service";
      edgeUnit = null;
      requireServiceEnableOptionPath = [ "alanix" "gitea" "enable" ];

      checkInterval = "15s";
      failureThreshold = 4;
      higherUnhealthyThreshold = 20;
      nodes = nodes;

      sync = {
        enable = true;
        interval = "2min";
        paths = cluster.services.gitea.dataPaths;
        sshKeySecret = cluster.syncSshKeySecret;
        authorizedPublicKey = cluster.services.gitea.syncPublicKey;
        allowedFromCIDR = cluster.wgSubnetCIDR;
        openFirewallOnWg = true;
      };

      dns = {
        enable = true;
        jobName = "gitea-failover";
        provider = cluster.dns.provider;
        interval = "2min";
        zone = cluster.domain;
        record = cluster.services.gitea.wanAccess.domain;
        tokenSecret = cluster.dns.apiTokenSecret;
        proxied = false;
        ttl = 60;
      };
    };
}
