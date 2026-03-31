{ lib, pkgs }:
let
  mkSocketProxy = import ../../lib/mkSocketProxy.nix { inherit pkgs; };
  isHttpEndpoint = endpoint: builtins.elem endpoint.protocol [ "http" "https" ];
  normalizeLocalAddress =
    address:
    if address == "0.0.0.0" then
      "127.0.0.1"
    else if address == "::" then
      "::1"
    else
      address;
  mkUpstream =
    endpoint:
    let
      address = normalizeLocalAddress endpoint.address;
    in
    if endpoint.protocol == "https" then
      "https://${address}:${toString endpoint.port}"
    else
      "${address}:${toString endpoint.port}";
in
{
  mkAssertions =
    {
      config,
      optionPrefix,
      endpoint,
      wireguardCfg,
    }:
    let
      listenAddress =
        if wireguardCfg.address != null then
          wireguardCfg.address
        else
          config.alanix.wireguard.vpnIP;
      listenPort =
        if wireguardCfg.port != null then
          wireguardCfg.port
        else
          endpoint.port;
    in
    [
      {
        assertion = !wireguardCfg.enable || config.alanix.wireguard.enable;
        message = "${optionPrefix}.wireguard requires alanix.wireguard.enable = true.";
      }
      {
        assertion = !wireguardCfg.enable || config.alanix.wireguard.vpnIP != null;
        message = "${optionPrefix}.wireguard requires alanix.wireguard.vpnIP to be set.";
      }
      {
        assertion = !wireguardCfg.enable || wireguardCfg.port != null;
        message = "${optionPrefix}.wireguard.port must be set explicitly when WireGuard exposure is enabled.";
      }
      {
        assertion =
          !wireguardCfg.enable
          || listenAddress != endpoint.address
          || listenPort != endpoint.port;
        message = "${optionPrefix}.wireguard would collide with the service's own listen address/port; keep the service internal or choose a different WireGuard address/port.";
      }
      {
        assertion = !wireguardCfg.enable || !wireguardCfg.tls || isHttpEndpoint endpoint;
        message = "${optionPrefix}.wireguard.tls only supports HTTP/HTTPS services.";
      }
    ];

  mkConfig =
    {
      config,
      serviceName,
      serviceDescription ? serviceName,
      endpoint,
      wireguardCfg,
    }:
    lib.mkIf wireguardCfg.enable (
      let
        listenAddress =
          if wireguardCfg.address != null then
            wireguardCfg.address
          else
            config.alanix.wireguard.vpnIP;
        listenPort =
          if wireguardCfg.port != null then
            wireguardCfg.port
          else
            endpoint.port;
        tlsName =
          if wireguardCfg.tlsName != null then
            wireguardCfg.tlsName
          else
            listenAddress;
        upstream = mkUpstream endpoint;
      in
      lib.mkMerge [
        {
          networking.firewall.interfaces.wg0.allowedTCPPorts = [ listenPort ];
        }
        (lib.mkIf wireguardCfg.tls {
          services.caddy.enable = true;
          services.caddy.virtualHosts."alanix-wireguard-${serviceName}" = {
            hostName = "https://${tlsName}:${toString listenPort}";
            listenAddresses = [ listenAddress ];
            extraConfig = ''
              tls internal
              reverse_proxy ${upstream}
            '';
          };
        })
        (lib.mkIf (!wireguardCfg.tls) (
          mkSocketProxy {
            name = "alanix-expose-wireguard-${serviceName}";
            description = "WireGuard exposure for ${serviceDescription}";
            inherit listenAddress listenPort;
            upstreamAddress = endpoint.address;
            upstreamPort = endpoint.port;
            freeBind = true;
          }
        ))
      ]
    );
}
