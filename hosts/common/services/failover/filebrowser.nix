{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceFailoverInstance = import ../../service-helpers/mk-service-failover-instance.nix;
in
{
  imports = [ ../../core/cluster.nix ];

  alanix.serviceFailover.instances.filebrowser = mkServiceFailoverInstance {
    inherit config lib hostname cluster;
    serviceName = "filebrowser";
    serviceUnit = "filebrowser.service";
    enable = cluster.services.filebrowser.enable;
  };
}
