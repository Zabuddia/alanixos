{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkPrioritizedServiceNodes = import ./mk-prioritized-service-nodes.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceFailover.instances.forgejo =
    let
      nodes = mkPrioritizedServiceNodes {
        inherit lib cluster;
        priorityOverrides = cluster.services.forgejo.priorityOverrides;
      };
    in
    {
      enable = cluster.services.forgejo.enable;
      nodeName = hostname;
      serviceUnit = "forgejo.service";
      edgeUnit = null;
      requireServiceEnableOptionPath = [ "alanix" "forgejo" "enable" ];

      checkInterval = "15s";
      failureThreshold = 4;
      higherUnhealthyThreshold = 20;
      nodes = nodes;

      sync = {
        enable = true;
        interval = "2min";
        paths = cluster.services.forgejo.dataPaths;
        sshKeySecret = cluster.syncSshKeySecret;
        authorizedPublicKey = cluster.services.forgejo.syncPublicKey;
        allowedFromCIDR = cluster.wgSubnetCIDR;
        openFirewallOnWg = true;
      };

      dns = {
        enable = true;
        jobName = "forgejo-failover";
        provider = cluster.dns.provider;
        interval = "2min";
        zone = cluster.domain;
        record = cluster.services.forgejo.wanAccess.domain;
        tokenSecret = cluster.dns.apiTokenSecret;
        proxied = false;
        ttl = 60;
      };
    };
}
