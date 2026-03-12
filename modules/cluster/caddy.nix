{ config, lib, pkgs, ... }:
let
  cluster = config.alanix.cluster;
  services = builtins.attrValues cluster.enabledServices;
  hasWanRoutes = lib.any (service: service.access.wan.enable) services;
  wireguardPorts =
    lib.concatMap
      (service: lib.optional service.access.wireguard.enable service.access.wireguard.port)
      services;

  mkWanVHost = service: {
    "${service.access.wan.domain}".extraConfig = ''
      encode zstd gzip
      reverse_proxy 127.0.0.1:${toString service.backendPort}
    '';
  };

  mkWireguardVHost = service: {
    "http://${cluster.currentNode.vpnIp}:${toString service.access.wireguard.port}".extraConfig = ''
      encode zstd gzip
      reverse_proxy 127.0.0.1:${toString service.backendPort}
    '';
  };

  mkTorHttpVHost = service: {
    "http://*.onion:${toString service.access.tor.httpLocalPort}".extraConfig = ''
      bind 127.0.0.1
      encode zstd gzip
      reverse_proxy 127.0.0.1:${toString service.backendPort}
    '';
  };

  mkTorHttpsVHost = service: {
    "https://*.onion:${toString service.access.tor.httpsLocalPort}".extraConfig = ''
      bind 127.0.0.1
      tls internal
      encode zstd gzip
      reverse_proxy 127.0.0.1:${toString service.backendPort}
    '';
  };

  virtualHosts = lib.mkMerge (
    lib.concatMap
      (service:
        []
        ++ lib.optional service.access.wan.enable (mkWanVHost service)
        ++ lib.optional service.access.wireguard.enable (mkWireguardVHost service)
        ++ lib.optional service.access.tor.enable (mkTorHttpVHost service)
        ++ lib.optional service.access.tor.enable (mkTorHttpsVHost service))
      services
  );
in
{
  config = lib.mkMerge [
    (lib.mkIf (cluster.isActiveNode && hasWanRoutes) {
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    })

    (lib.mkIf (cluster.isActiveNode && wireguardPorts != [ ]) {
      networking.firewall.interfaces.${cluster.settings.wireguard.interface}.allowedTCPPorts = wireguardPorts;
    })

    (lib.mkIf cluster.isActiveNode {
      services.caddy = {
        enable = services != [ ];
        package = pkgs.caddy;
        virtualHosts = virtualHosts;
      };
    })
  ];
}
