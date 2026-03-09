{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ../core/cluster.nix
    ../../../modules/invidious.nix
  ];

  alanix.invidious = {
    enable = cluster.services.invidious.enable;
    # Role controller starts/stops invidious declaratively; do not auto-start by default.
    active = lib.mkDefault false;
    listenAddress = "127.0.0.1";
    port = cluster.services.invidious.backendPort;
    openFirewall = false;
    stateDir = cluster.services.invidious.stateDir;
    uid = cluster.services.invidious.uid;
    gid = cluster.services.invidious.gid;
    settings = cluster.services.invidious.settings;
    hmacKeySecret = cluster.services.invidious.hmacKeySecret;

    database = {
      createLocally = cluster.services.invidious.database.createLocally;
      host = cluster.services.invidious.database.host;
      port = cluster.services.invidious.database.port;
      passwordSecret = cluster.services.invidious.database.passwordSecret;
    };

    companion = {
      enable = cluster.services.invidious.companion.enable;
      listenAddress = cluster.services.invidious.companion.listenAddress;
    };

    users = cluster.services.invidious.users;

    wanAccess = {
      enable = cluster.services.invidious.wanAccess.enable;
      domain = cluster.services.invidious.wanAccess.domain;
      openFirewall = cluster.services.invidious.wanAccess.openFirewall;
    };

    wireguardAccess = {
      enable = cluster.services.invidious.wireguardAccess.enable;
      listenAddress = cluster.nodes.${hostname}.vpnIP;
      port = cluster.services.invidious.wireguardAccess.port;
      interface = "wg0";
    };

    torAccess = {
      enable = cluster.services.invidious.torAccess.enable;
      serviceName = cluster.services.invidious.torAccess.onionServiceName;
      enableHttp = cluster.services.invidious.torAccess.enableHttp;
      httpLocalPort = cluster.services.invidious.torAccess.httpLocalPort;
      httpVirtualPort = cluster.services.invidious.torAccess.httpVirtualPort;
      enableHttps = cluster.services.invidious.torAccess.enableHttps;
      httpsLocalPort = cluster.services.invidious.torAccess.httpsLocalPort;
      httpsVirtualPort = cluster.services.invidious.torAccess.httpsVirtualPort;
      version = cluster.services.invidious.torAccess.version;
      secretKeySecret = cluster.services.invidious.torAccess.secretKeySecret;
    };
  };
}
