{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceFailoverInstance = import ./mk-service-failover-instance.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceFailover.instances.forgejo = mkServiceFailoverInstance {
    inherit config lib hostname cluster;
    serviceName = "forgejo";
    serviceUnit = "forgejo.service";
    enable = cluster.services.forgejo.enable;
  };
}
