{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../modules/forgejo.nix
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

    wireguardAccess = {
      enable = cluster.services.forgejo.wireguardAccess.enable;
      listenAddress = cluster.nodes.${hostname}.vpnIP;
      port = cluster.services.forgejo.wireguardAccess.port;
      interface = "wg0";
    };

    torAccess = {
      enable = cluster.services.forgejo.torAccess.enable;
      serviceName = cluster.services.forgejo.torAccess.onionServiceName;
      localPort = cluster.services.forgejo.torAccess.localPort;
      virtualPort = cluster.services.forgejo.torAccess.virtualPort;
      version = cluster.services.forgejo.torAccess.version;
      secretKeySecret = cluster.services.forgejo.torAccess.secretKeySecret;
    };

    users = {
      # buddia = {
      #   admin = true;
      #   email = "buddia@${cluster.domain}";
      #   fullName = "buddia";
      #   passwordSecret = "service-passwords/buddia";
      #   mustChangePassword = false;
      # };
      buddia = {
        admin = true;
        email = "fife.alan@protonmail.com";
        fullName = "Alan Fife";
        passwordSecret = "service-passwords/buddia";
        mustChangePassword = false;
      };
    };
  };
}
