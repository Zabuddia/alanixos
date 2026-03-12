{ config, lib, ... }:
let
  cluster = config.alanix.cluster;
  isActive = cluster.isActiveNode;
  wgInterface = cluster.settings.wireguard.interface;
  wgAddress = cluster.currentNode.vpnIp;

  filebrowser = cluster.services.filebrowser;
  forgejo = cluster.services.forgejo;
  immich = cluster.services.immich;
  invidious = cluster.services.invidious;

  mkTorAccess = torCfg: {
    enable = torCfg.enable;
    serviceName = torCfg.serviceName;
    enableHttp = torCfg.enable;
    httpLocalPort = torCfg.httpLocalPort;
    httpVirtualPort = torCfg.httpVirtualPort;
    enableHttps = torCfg.enable;
    httpsLocalPort = torCfg.httpsLocalPort;
    httpsVirtualPort = torCfg.httpsVirtualPort;
    version = torCfg.version;
    secretKeySecret = torCfg.secretKeySecret;
  };
in
{
  imports = [
    ../filebrowser.nix
    ../forgejo.nix
    ../immich.nix
    ../invidious.nix
  ];

  config = lib.mkMerge [
    (lib.mkIf filebrowser.enable {
      alanix.filebrowser = {
        enable = true;
        active = isActive;
        listenAddress = "127.0.0.1";
        port = filebrowser.backendPort;
        openFirewall = false;
        root = filebrowser.state.rootDir;
        database = filebrowser.state.databasePath;
        uid = filebrowser.uid;
        gid = filebrowser.gid;
        users = filebrowser.bootstrap.users;
        wanAccess = {
          enable = filebrowser.access.wan.enable;
          domain = filebrowser.access.wan.domain;
          openFirewall = false;
        };
        clusterAccess = {
          enable = filebrowser.access.wireguard.enable;
          listenAddress = wgAddress;
          port = filebrowser.access.wireguard.port;
          interface = wgInterface;
        };
        torAccess = mkTorAccess filebrowser.access.tor;
      };
    })

    (lib.mkIf forgejo.enable {
      alanix.forgejo = {
        enable = true;
        active = isActive;
        listenAddress = "127.0.0.1";
        port = forgejo.backendPort;
        openFirewall = false;
        stateDir = forgejo.state.stateDir;
        uid = forgejo.uid;
        gid = forgejo.gid;
        allowRegistration = forgejo.bootstrap.allowRegistration;
        users = forgejo.bootstrap.users;
        wanAccess = {
          enable = forgejo.access.wan.enable;
          domain = forgejo.access.wan.domain;
          openFirewall = false;
          canonicalRootUrl = forgejo.access.wan.canonicalRootUrl;
        };
        clusterAccess = {
          enable = forgejo.access.wireguard.enable;
          listenAddress = wgAddress;
          port = forgejo.access.wireguard.port;
          interface = wgInterface;
        };
        torAccess = mkTorAccess forgejo.access.tor;
      };
    })

    (lib.mkIf immich.enable {
      alanix.immich = {
        enable = true;
        active = isActive;
        listenAddress = "127.0.0.1";
        port = immich.backendPort;
        openFirewall = false;
        stateDir = immich.state.stateDir;
        uid = immich.uid;
        gid = immich.gid;
        settings = immich.settings;
        environment = immich.environment;
        accelerationDevices = immich.accelerationDevices;
        adminEmail = immich.bootstrap.adminEmail;
        adminPasswordSecret = immich.bootstrap.adminPasswordSecret;
        users = immich.bootstrap.users;
        database = immich.database;
        redis = immich.redis;
        machineLearning = immich.machineLearning;
        wanAccess = {
          enable = immich.access.wan.enable;
          domain = immich.access.wan.domain;
          openFirewall = false;
        };
        clusterAccess = {
          enable = immich.access.wireguard.enable;
          listenAddress = wgAddress;
          port = immich.access.wireguard.port;
          interface = wgInterface;
        };
        torAccess = mkTorAccess immich.access.tor;
      };
    })

    (lib.mkIf invidious.enable {
      alanix.invidious = {
        enable = true;
        active = isActive;
        listenAddress = "127.0.0.1";
        port = invidious.backendPort;
        openFirewall = false;
        stateDir = invidious.state.stateDir;
        uid = invidious.uid;
        gid = invidious.gid;
        cookieDomain = invidious.cookieDomain;
        settings = invidious.settings;
        hmacKeySecret = invidious.bootstrap.hmacKeySecret;
        database = invidious.database;
        companion = invidious.companion;
        users = invidious.bootstrap.users;
        wanAccess = {
          enable = invidious.access.wan.enable;
          domain = invidious.access.wan.domain;
          openFirewall = false;
        };
        clusterAccess = {
          enable = invidious.access.wireguard.enable;
          listenAddress = wgAddress;
          port = invidious.access.wireguard.port;
          interface = wgInterface;
        };
        torAccess = mkTorAccess invidious.access.tor;
      };
    })
  ];
}
