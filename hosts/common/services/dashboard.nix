{ config, lib, hostname, ... }:
let
  cluster = config.alanix.cluster;
  serviceNames = builtins.attrNames cluster.services;

  mkWanEndpoint =
    serviceName:
    let
      svc = cluster.services.${serviceName};
    in
    lib.optional (svc.enable && svc.wanAccess.enable && svc.wanAccess.domain != null) {
      name = "${serviceName}-wan";
      url = "https://${svc.wanAccess.domain}";
    };

  mkWireguardEndpoints =
    serviceName:
    let
      svc = cluster.services.${serviceName};
    in
    lib.optionals (svc.enable && svc.wireguardAccess.enable) (
      lib.mapAttrsToList (nodeName: node: {
        name = "${serviceName}-wg-${nodeName}";
        url = "http://${node.vpnIP}:${toString svc.wireguardAccess.port}";
      }) cluster.nodes
    );

  endpointChecks = lib.concatLists (
    map (serviceName: mkWanEndpoint serviceName ++ mkWireguardEndpoints serviceName) serviceNames
  );
in
{
  imports = [
    ../core/cluster.nix
    ../../../modules/dashboard.nix
  ];

  alanix.dashboard = {
    enable = cluster.services.dashboard.enable;
    active =
      if cluster.services.dashboard.activeNode == null then
        true
      else
        cluster.services.dashboard.activeNode == hostname;
    listenAddress = "127.0.0.1";
    port = cluster.services.dashboard.backendPort;
    openFirewall = false;
    adminUser = cluster.services.dashboard.adminUser;
    adminPasswordSecret = cluster.services.dashboard.adminPasswordSecret;
    prometheusListenAddress = "127.0.0.1";
    prometheusPort = cluster.services.dashboard.prometheusPort;
    blackboxPort = cluster.services.dashboard.blackboxPort;
    nodeExporterListenAddress = cluster.nodes.${hostname}.vpnIP;
    nodeExporterPort = cluster.services.dashboard.nodeExporterPort;
    nodeExporterInterface = cluster.services.dashboard.nodeExporterInterface;
    metricsInterval = cluster.services.dashboard.metricsInterval;
    scrapeTargets = lib.mapAttrsToList (_: node:
      "${node.vpnIP}:${toString cluster.services.dashboard.nodeExporterPort}"
    ) cluster.nodes;
    inherit endpointChecks;

    wanAccess = {
      enable = cluster.services.dashboard.wanAccess.enable;
      domain = cluster.services.dashboard.wanAccess.domain;
      openFirewall = cluster.services.dashboard.wanAccess.openFirewall;
    };

    wireguardAccess = {
      enable = cluster.services.dashboard.wireguardAccess.enable;
      listenAddress = cluster.nodes.${hostname}.vpnIP;
      port = cluster.services.dashboard.wireguardAccess.port;
      interface = "wg0";
    };

    torAccess = {
      enable = cluster.services.dashboard.torAccess.enable;
      serviceName = cluster.services.dashboard.torAccess.onionServiceName;
      enableHttp = cluster.services.dashboard.torAccess.enableHttp;
      httpLocalPort = cluster.services.dashboard.torAccess.httpLocalPort;
      httpVirtualPort = cluster.services.dashboard.torAccess.httpVirtualPort;
      enableHttps = cluster.services.dashboard.torAccess.enableHttps;
      httpsLocalPort = cluster.services.dashboard.torAccess.httpsLocalPort;
      httpsVirtualPort = cluster.services.dashboard.torAccess.httpsVirtualPort;
      version = cluster.services.dashboard.torAccess.version;
      secretKeySecret = cluster.services.dashboard.torAccess.secretKeySecret;
    };
  };
}
