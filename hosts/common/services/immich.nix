{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
in
{
  imports = [
    ../core/cluster.nix
    ../../../modules/immich.nix
  ];

  alanix.immich = {
    enable = cluster.services.immich.enable;
    # Role controller starts/stops immich declaratively; do not auto-start by default.
    active = lib.mkDefault false;
    listenAddress = "127.0.0.1";
    port = cluster.services.immich.backendPort;
    openFirewall = false;
    stateDir = cluster.services.immich.stateDir;
    uid = cluster.services.immich.uid;
    gid = cluster.services.immich.gid;
    settings = cluster.services.immich.settings;
    environment = cluster.services.immich.environment;
    accelerationDevices = cluster.services.immich.accelerationDevices;

    database = {
      createLocally = cluster.services.immich.database.createLocally;
      host = cluster.services.immich.database.host;
      port = cluster.services.immich.database.port;
      name = cluster.services.immich.database.name;
      user = cluster.services.immich.database.user;
      enableVectorChord = cluster.services.immich.database.enableVectorChord;
      enableVectors = cluster.services.immich.database.enableVectors;
      passwordSecret = cluster.services.immich.database.passwordSecret;
    };

    redis = {
      enable = cluster.services.immich.redis.enable;
      host = cluster.services.immich.redis.host;
      port = cluster.services.immich.redis.port;
    };

    machineLearning = {
      enable = cluster.services.immich.machineLearning.enable;
      environment = cluster.services.immich.machineLearning.environment;
    };

    adminEmail = cluster.services.immich.reconcileAdminEmail;
    adminPasswordSecret = cluster.services.immich.reconcileAdminPasswordSecret;
    users = cluster.services.immich.users;

    wanAccess = {
      enable = cluster.services.immich.wanAccess.enable;
      domain = cluster.services.immich.wanAccess.domain;
      openFirewall = cluster.services.immich.wanAccess.openFirewall;
    };

    clusterAccess = {
      enable = cluster.services.immich.clusterAccess.enable;
      listenAddress = cluster.nodes.${hostname}.clusterAddress;
      port = cluster.services.immich.clusterAccess.port;
      interface = cluster.transport.interface;
    };

    torAccess = {
      enable = cluster.services.immich.torAccess.enable;
      serviceName = cluster.services.immich.torAccess.onionServiceName;
      enableHttp = cluster.services.immich.torAccess.enableHttp;
      httpLocalPort = cluster.services.immich.torAccess.httpLocalPort;
      httpVirtualPort = cluster.services.immich.torAccess.httpVirtualPort;
      enableHttps = cluster.services.immich.torAccess.enableHttps;
      httpsLocalPort = cluster.services.immich.torAccess.httpsLocalPort;
      httpsVirtualPort = cluster.services.immich.torAccess.httpsVirtualPort;
      version = cluster.services.immich.torAccess.version;
      secretKeySecret = cluster.services.immich.torAccess.secretKeySecret;
    };
  };
}
