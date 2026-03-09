{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceFailoverInstance = import ../../service-helpers/mk-service-failover-instance.nix;
in
{
  imports = [ ../../core/cluster.nix ];

  alanix.serviceFailover.instances.dashboard = mkServiceFailoverInstance {
    inherit config lib hostname cluster;
    serviceName = "dashboard";
    serviceUnit = "prometheus.service";
    edgeUnit = "grafana.service";
    enable = cluster.services.dashboard.enable;
  };
}
