{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../modules/filebrowser.nix
  ];

  alanix.filebrowser = {
    enable = true;
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
      localPort = cluster.services.filebrowser.torAccess.localPort;
      virtualPort = cluster.services.filebrowser.torAccess.virtualPort;
      version = cluster.services.filebrowser.torAccess.version;
      secretKeySecret = cluster.services.filebrowser.torAccess.secretKeySecret;
    };

    users = {
      admin = {
        passwordSecret = "service-passwords/admin";
        admin = true;
        scope = ".";
      };

      buddia = {
        passwordSecret = "service-passwords/buddia";
        admin = false;
        scope = "users/buddia";
      };
    };
  };
}
