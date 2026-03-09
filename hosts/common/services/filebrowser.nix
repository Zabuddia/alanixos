{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ../core/cluster.nix
    ../../../modules/filebrowser.nix
  ];

  alanix.filebrowser = {
    enable = cluster.services.filebrowser.enable;
    # Role controller starts/stops filebrowser declaratively; do not auto-start by default.
    active = lib.mkDefault false;
    listenAddress = "127.0.0.1";
    port = cluster.services.filebrowser.backendPort;
    openFirewall = false;
    root = "/srv/filebrowser";
    database = "/var/lib/filebrowser/filebrowser.db";
    uid = cluster.services.filebrowser.uid;
    gid = cluster.services.filebrowser.gid;
    wanAccess = {
      enable = cluster.services.filebrowser.wanAccess.enable;
      domain = cluster.services.filebrowser.wanAccess.domain;
      openFirewall = cluster.services.filebrowser.wanAccess.openFirewall;
    };

    wireguardAccess = {
      enable = cluster.services.filebrowser.wireguardAccess.enable;
      listenAddress = cluster.nodes.${hostname}.vpnIP;
      port = cluster.services.filebrowser.wireguardAccess.port;
      interface = "wg0";
    };

    torAccess = {
      enable = cluster.services.filebrowser.torAccess.enable;
      serviceName = cluster.services.filebrowser.torAccess.onionServiceName;
      enableHttp = cluster.services.filebrowser.torAccess.enableHttp;
      httpLocalPort = cluster.services.filebrowser.torAccess.httpLocalPort;
      httpVirtualPort = cluster.services.filebrowser.torAccess.httpVirtualPort;
      enableHttps = cluster.services.filebrowser.torAccess.enableHttps;
      httpsLocalPort = cluster.services.filebrowser.torAccess.httpsLocalPort;
      httpsVirtualPort = cluster.services.filebrowser.torAccess.httpsVirtualPort;
      version = cluster.services.filebrowser.torAccess.version;
      secretKeySecret = cluster.services.filebrowser.torAccess.secretKeySecret;
    };

    users = cluster.services.filebrowser.users;
  };
}
