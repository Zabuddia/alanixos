{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceFailoverInstance = import ./mk-service-failover-instance.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceFailover.instances.vaultwarden = mkServiceFailoverInstance {
    inherit config lib hostname cluster;
    serviceName = "vaultwarden";
    serviceUnit = "vaultwarden.service";
    enable = cluster.services.vaultwarden.enable;
  };
}
