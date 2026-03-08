{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../modules/vaultwarden.nix
  ];

  alanix.vaultwarden = {
    enable = cluster.services.vaultwarden.enable;
    # Role controller starts/stops vaultwarden declaratively; do not auto-start by default.
    active = lib.mkDefault false;
    listenAddress = "127.0.0.1";
    port = cluster.services.vaultwarden.backendPort;
    openFirewall = false;
    stateDir = cluster.services.vaultwarden.stateDir;
    dbBackend = cluster.services.vaultwarden.dbBackend;
    settings = cluster.services.vaultwarden.settings;
    adminTokenSecret = cluster.services.vaultwarden.adminTokenSecret;
    uid = cluster.services.vaultwarden.uid;
    gid = cluster.services.vaultwarden.gid;

    wanAccess = {
      enable = cluster.services.vaultwarden.wanAccess.enable;
      domain = cluster.services.vaultwarden.wanAccess.domain;
      openFirewall = cluster.services.vaultwarden.wanAccess.openFirewall;
    };

    wireguardAccess = {
      enable = cluster.services.vaultwarden.wireguardAccess.enable;
      listenAddress = cluster.nodes.${hostname}.vpnIP;
      port = cluster.services.vaultwarden.wireguardAccess.port;
      interface = "wg0";
    };

    torAccess = {
      enable = cluster.services.vaultwarden.torAccess.enable;
      serviceName = cluster.services.vaultwarden.torAccess.onionServiceName;
      enableHttp = cluster.services.vaultwarden.torAccess.enableHttp;
      httpLocalPort = cluster.services.vaultwarden.torAccess.httpLocalPort;
      httpVirtualPort = cluster.services.vaultwarden.torAccess.httpVirtualPort;
      enableHttps = cluster.services.vaultwarden.torAccess.enableHttps;
      httpsLocalPort = cluster.services.vaultwarden.torAccess.httpsLocalPort;
      httpsVirtualPort = cluster.services.vaultwarden.torAccess.httpsVirtualPort;
      version = cluster.services.vaultwarden.torAccess.version;
      secretKeySecret = cluster.services.vaultwarden.torAccess.secretKeySecret;
    };
  };
}
