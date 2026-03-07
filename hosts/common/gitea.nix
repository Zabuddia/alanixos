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

    reverseProxy = {
      enable = true;
      domain = cluster.services.gitea.domain;
      openFirewall = cluster.services.gitea.reverseProxyOpenFirewall;
    };

    wireguardAccess = {
      enable = cluster.services.gitea.wireguardAccess.enable;
      listenAddress = cluster.nodes.${hostname}.vpnIP;
      port = cluster.services.gitea.wireguardAccess.port;
      interface = "wg0";
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
