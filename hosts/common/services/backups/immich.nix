{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceBackupInstance = import ../../service-helpers/mk-service-backup-instance.nix;
in
{
  imports = [ ../../core/cluster.nix ];

  alanix.serviceBackups.instances.immich = mkServiceBackupInstance {
    inherit config lib hostname cluster;
    serviceName = "immich";
  };
}
