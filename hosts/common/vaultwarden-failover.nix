{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkPrioritizedServiceNodes = import ./mk-prioritized-service-nodes.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceFailover.instances.vaultwarden =
    let
      nodes = mkPrioritizedServiceNodes {
        inherit lib cluster;
        priorityOverrides = cluster.services.vaultwarden.priorityOverrides;
      };
    in
    {
      enable = cluster.services.vaultwarden.enable;
      nodeName = hostname;
      serviceUnit = "vaultwarden.service";
      edgeUnit = null;
      requireServiceEnableOptionPath = [ "alanix" "vaultwarden" "enable" ];

      checkInterval = "15s";
      failureThreshold = 4;
      higherUnhealthyThreshold = 20;
      nodes = nodes;

      sync = {
        enable = true;
        interval = "2min";
        paths = cluster.services.vaultwarden.dataPaths;
        sshKeySecret = cluster.syncSshKeySecret;
        authorizedPublicKey = cluster.services.vaultwarden.syncPublicKey;
        allowedFromCIDR = cluster.wgSubnetCIDR;
        openFirewallOnWg = true;
      };

      dns = {
        enable = true;
        jobName = "vaultwarden-failover";
        provider = cluster.dns.provider;
        interval = "2min";
        zone = cluster.domain;
        record = cluster.services.vaultwarden.wanAccess.domain;
        tokenSecret = cluster.dns.apiTokenSecret;
        proxied = false;
        ttl = 60;
      };
    };
}
