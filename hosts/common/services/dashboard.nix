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

  mkClusterEndpoints =
    serviceName:
    let
      svc = cluster.services.${serviceName};
    in
    lib.optionals (svc.enable && svc.clusterAccess.enable) (
      lib.mapAttrsToList (nodeName: node: {
        name = "${serviceName}-cluster-${nodeName}";
        url = "http://${node.clusterAddress}:${toString svc.clusterAccess.port}";
      }) cluster.nodes
    );

  endpointChecks = lib.concatLists (
    map (serviceName: mkWanEndpoint serviceName ++ mkClusterEndpoints serviceName) serviceNames
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
      clusterUrl =
        if svc.clusterAccess.enable then
          "http://${cluster.nodes.${hostname}.clusterAddress}:${toString svc.clusterAccess.port}"
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
    prometheusListenAddress = cluster.nodes.${hostname}.clusterAddress;
    prometheusPort = cluster.services.dashboard.prometheusPort;
    blackboxPort = cluster.services.dashboard.blackboxPort;
    nodeExporterListenAddress = cluster.nodes.${hostname}.clusterAddress;
    nodeExporterPort = cluster.services.dashboard.nodeExporterPort;
    nodeExporterInterface = cluster.services.dashboard.nodeExporterInterface;
    metricsInterval = cluster.services.dashboard.metricsInterval;
    scrapeTargets = lib.mapAttrsToList (nodeName: node: {
      target = "${node.clusterAddress}:${toString cluster.services.dashboard.nodeExporterPort}";
      node = nodeName;
      clusterAddress = node.clusterAddress;
      clusterDnsName = node.clusterDnsName;
    }) cluster.nodes;
    inherit endpointChecks;
    inherit serviceDirectory;

    wanAccess = {
      enable = cluster.services.dashboard.wanAccess.enable;
      domain = cluster.services.dashboard.wanAccess.domain;
      openFirewall = cluster.services.dashboard.wanAccess.openFirewall;
    };

    clusterAccess = {
      enable = cluster.services.dashboard.clusterAccess.enable;
      listenAddress = cluster.nodes.${hostname}.clusterAddress;
      port = cluster.services.dashboard.clusterAccess.port;
      interface = cluster.transport.interface;
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
