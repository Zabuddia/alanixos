{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  mkServiceBackupInstance = import ./mk-service-backup-instance.nix;
in
{
  imports = [ ./cluster.nix ];

  alanix.serviceBackups.instances.vaultwarden = mkServiceBackupInstance {
    inherit config lib hostname cluster;
    serviceName = "vaultwarden";
  };
}
