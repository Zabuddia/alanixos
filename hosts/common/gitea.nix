{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ./cluster.nix
    ../../modules/gitea.nix
  ];

  alanix.gitea = {
    enable = cluster.services.gitea.enable;
    # Role controller starts/stops gitea declaratively; do not auto-start by default.
    active = lib.mkDefault false;
    listenAddress = "127.0.0.1";
    port = cluster.services.gitea.backendPort;
    openFirewall = false;
    stateDir = cluster.services.gitea.stateDir;
    uid = cluster.services.gitea.uid;
    gid = cluster.services.gitea.gid;

    wanAccess = {
      enable = cluster.services.gitea.wanAccess.enable;
      domain = cluster.services.gitea.wanAccess.domain;
      openFirewall = cluster.services.gitea.wanAccess.openFirewall;
    };

    wireguardAccess = {
      enable = cluster.services.gitea.wireguardAccess.enable;
      listenAddress = cluster.nodes.${hostname}.vpnIP;
      port = cluster.services.gitea.wireguardAccess.port;
      interface = "wg0";
    };

    torAccess = {
      enable = cluster.services.gitea.torAccess.enable;
      serviceName = cluster.services.gitea.torAccess.onionServiceName;
      localPort = cluster.services.gitea.torAccess.localPort;
      virtualPort = cluster.services.gitea.torAccess.virtualPort;
      version = cluster.services.gitea.torAccess.version;
      secretKeySecret = cluster.services.gitea.torAccess.secretKeySecret;
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
