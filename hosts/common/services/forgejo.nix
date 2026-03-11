{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ../core/cluster.nix
    ../../../modules/forgejo.nix
  ];

  alanix.forgejo = {
    enable = cluster.services.forgejo.enable;
    # Role controller starts/stops forgejo declaratively; do not auto-start by default.
    active = lib.mkDefault false;
    listenAddress = "127.0.0.1";
    port = cluster.services.forgejo.backendPort;
    openFirewall = false;
    stateDir = cluster.services.forgejo.stateDir;
    uid = cluster.services.forgejo.uid;
    gid = cluster.services.forgejo.gid;

    wanAccess = {
      enable = cluster.services.forgejo.wanAccess.enable;
      domain = cluster.services.forgejo.wanAccess.domain;
      openFirewall = cluster.services.forgejo.wanAccess.openFirewall;
      canonicalRootUrl = cluster.services.forgejo.wanAccess.canonicalRootUrl;
    };

    clusterAccess = {
      enable = cluster.services.forgejo.clusterAccess.enable;
      listenAddress = cluster.nodes.${hostname}.clusterAddress;
      port = cluster.services.forgejo.clusterAccess.port;
      interface = cluster.transport.interface;
    };

    torAccess = {
      enable = cluster.services.forgejo.torAccess.enable;
      serviceName = cluster.services.forgejo.torAccess.onionServiceName;
      enableHttp = cluster.services.forgejo.torAccess.enableHttp;
      httpLocalPort = cluster.services.forgejo.torAccess.httpLocalPort;
      httpVirtualPort = cluster.services.forgejo.torAccess.httpVirtualPort;
      enableHttps = cluster.services.forgejo.torAccess.enableHttps;
      httpsLocalPort = cluster.services.forgejo.torAccess.httpsLocalPort;
      httpsVirtualPort = cluster.services.forgejo.torAccess.httpsVirtualPort;
      version = cluster.services.forgejo.torAccess.version;
      secretKeySecret = cluster.services.forgejo.torAccess.secretKeySecret;
    };

    users = cluster.services.forgejo.users;
  };
}
