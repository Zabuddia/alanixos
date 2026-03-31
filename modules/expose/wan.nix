{ lib, pkgs }:
let
  mkSocketProxy = import ../../lib/mkSocketProxy.nix { inherit pkgs; };
  isHttpEndpoint = endpoint: builtins.elem endpoint.protocol [ "http" "https" ];
  effectiveWanPort =
    endpoint: wanCfg:
    if wanCfg.port != null then
      wanCfg.port
    else if isHttpEndpoint endpoint then
      if wanCfg.tls then 443 else 80
    else
      endpoint.port;
  siteLabel =
    domain: port: tls:
    let
      defaultPort = if tls then 443 else 80;
    in
    if domain != null then
      if port == defaultPort then domain else "${domain}:${toString port}"
    else
      ":${toString port}";
in
{
  mkAssertions =
    {
      optionPrefix,
      endpoint,
      wanCfg,
      ...
    }:
    let
      listenAddress = if wanCfg.address != null then wanCfg.address else "0.0.0.0";
      listenPort = effectiveWanPort endpoint wanCfg;
    in
    [
      {
        assertion =
          !wanCfg.enable
          || !isHttpEndpoint endpoint
          || wanCfg.domain != null
          || !wanCfg.tls;
        message = "${optionPrefix}.wan requires domain when tls = true.";
      }
      {
        assertion =
          !wanCfg.enable
          || isHttpEndpoint endpoint
          || !wanCfg.tls;
        message = "${optionPrefix}.wan does not support tls termination for raw TCP services yet.";
      }
      {
        assertion =
          !wanCfg.enable
          || isHttpEndpoint endpoint
          || listenAddress != endpoint.address
          || listenPort != endpoint.port;
        message = "${optionPrefix}.wan would collide with the service's own listen address/port; keep the service internal or choose a different WAN address/port.";
      }
    ];

  mkConfig =
    {
      serviceName,
      serviceDescription ? serviceName,
      endpoint,
      wanCfg,
      ...
    }:
    lib.mkIf wanCfg.enable (
      let
        listenAddress = if wanCfg.address != null then wanCfg.address else "0.0.0.0";
        listenPort = effectiveWanPort endpoint wanCfg;
        firewallPorts =
          lib.unique (
            if isHttpEndpoint endpoint && wanCfg.tls then
              [ 80 listenPort ]
            else
              [ listenPort ]
          );
      in
      if isHttpEndpoint endpoint then
        let
          upstream =
            if endpoint.protocol == "https" then
              "https://${endpoint.address}:${toString endpoint.port}"
            else
              "${endpoint.address}:${toString endpoint.port}";
        in
        {
          networking.firewall.allowedTCPPorts = firewallPorts;
          services.caddy.enable = true;
          services.caddy.virtualHosts."alanix-wan-${serviceName}" = {
            hostName = siteLabel wanCfg.domain listenPort wanCfg.tls;
            listenAddresses = lib.optionals (listenAddress != "0.0.0.0") [ listenAddress ];
            extraConfig = ''
              reverse_proxy ${upstream}
            '';
          };
        }
      else
        {
          networking.firewall.allowedTCPPorts = firewallPorts;
        }
        // mkSocketProxy {
          name = "alanix-expose-wan-${serviceName}";
          description = "WAN exposure for ${serviceDescription}";
          inherit listenAddress listenPort;
          upstreamAddress = endpoint.address;
          upstreamPort = endpoint.port;
        }
    );
}
