{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceFailoverInstance = import ../../service-helpers/mk-service-failover-instance.nix;
in
{
  imports = [ ../../core/cluster.nix ];

  alanix.serviceFailover.instances.invidious = mkServiceFailoverInstance {
    inherit config lib hostname cluster;
    serviceName = "invidious";
    serviceUnit =
      if cluster.services.invidious.database.createLocally then
        "postgresql.service"
      else
        "invidious.service";
    edgeUnit =
      if cluster.services.invidious.database.createLocally then
        "invidious.service"
      else
        null;
    enable = cluster.services.invidious.enable;
  };
}
