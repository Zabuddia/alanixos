{ config, lib, ... }:
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
    reverseProxy = {
      enable = true;
      domain = cluster.services.filebrowser.domain;
      openFirewall = cluster.services.filebrowser.reverseProxyOpenFirewall;
    };

    users = {
      admin = {
        passwordSecret = "filebrowser-passwords/admin";
        admin = true;
        scope = ".";
      };

      buddia = {
        passwordSecret = "filebrowser-passwords/buddia";
        admin = false;
        scope = "users/buddia";
      };
    };
  };
}
