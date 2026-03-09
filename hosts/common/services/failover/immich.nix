{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceFailoverInstance = import ../../service-helpers/mk-service-failover-instance.nix;
in
{
  imports = [ ../../core/cluster.nix ];

  alanix.serviceFailover.instances.immich = mkServiceFailoverInstance {
    inherit config lib hostname cluster;
    serviceName = "immich";
    serviceUnit = "immich-server.service";
    edgeUnit = if cluster.services.immich.machineLearning.enable then "immich-machine-learning.service" else null;
    enable = cluster.services.immich.enable;
  };
}
