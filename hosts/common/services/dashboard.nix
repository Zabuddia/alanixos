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

  serviceDirectory = lib.map (serviceName:
    let
      svc = cluster.services.${serviceName};
      torScheme =
        if svc.torAccess.enableHttps then
          "https"
        else if svc.torAccess.enableHttp then
          "http"
        else
          null;
    in
    {
      service = serviceName;
      wanUrl =
        if svc.wanAccess.enable && svc.wanAccess.domain != null then
          "https://${svc.wanAccess.domain}"
        else
          null;
      wireguardUrl =
        if svc.wireguardAccess.enable then
          "http://${cluster.nodes.${hostname}.vpnIP}:${toString svc.wireguardAccess.port}"
        else
          null;
      torServiceName = if svc.torAccess.enable then svc.torAccess.onionServiceName else null;
      inherit torScheme;
    }
  ) (lib.filter (serviceName: cluster.services.${serviceName}.enable) serviceNames);
in
{
  imports = [
    ../core/cluster.nix
    ../../../modules/dashboard.nix
  ];

  alanix.dashboard = {
    enable = cluster.services.dashboard.enable;
    # Role controller starts/stops dashboard declaratively; do not auto-start by default.
    active = lib.mkDefault false;
    listenAddress = "127.0.0.1";
    port = cluster.services.dashboard.backendPort;
    openFirewall = false;
    adminUser = cluster.services.dashboard.adminUser;
    adminPasswordSecret = cluster.services.dashboard.adminPasswordSecret;
    prometheusListenAddress = cluster.nodes.${hostname}.vpnIP;
    prometheusPort = cluster.services.dashboard.prometheusPort;
    blackboxPort = cluster.services.dashboard.blackboxPort;
    nodeExporterListenAddress = cluster.nodes.${hostname}.vpnIP;
    nodeExporterPort = cluster.services.dashboard.nodeExporterPort;
    nodeExporterInterface = cluster.services.dashboard.nodeExporterInterface;
    metricsInterval = cluster.services.dashboard.metricsInterval;
    scrapeTargets = lib.mapAttrsToList (nodeName: node: {
      target = "${node.vpnIP}:${toString cluster.services.dashboard.nodeExporterPort}";
      node = nodeName;
      privateIp = node.vpnIP;
      publicHost = node.wireguardEndpointHost or null;
    }) cluster.nodes;
    inherit endpointChecks;
    inherit serviceDirectory;

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
