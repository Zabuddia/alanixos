{ lib, pkgs }:
let
  mkSocketProxy = import ../../lib/mkSocketProxy.nix { inherit pkgs; };
  isHttpEndpoint = endpoint: builtins.elem endpoint.protocol [ "http" "https" ];
  isWildcardAddress = address: builtins.elem address [ "0.0.0.0" "::" ];
  effectiveListenAddress =
    tailscaleCfg:
    if tailscaleCfg.address != null then
      tailscaleCfg.address
    else
      "0.0.0.0";
  mkUpstream =
    endpoint:
    if endpoint.protocol == "https" then
      "https://${endpoint.address}:${toString endpoint.port}"
    else
      "${endpoint.address}:${toString endpoint.port}";
in
{
  mkAssertions =
    {
      config,
      optionPrefix,
      endpoint,
      tailscaleCfg,
    }:
    let
      listenAddress = effectiveListenAddress tailscaleCfg;
      listenPort =
        if tailscaleCfg.port != null then
          tailscaleCfg.port
        else
          endpoint.port;
      portCollides = listenPort == endpoint.port;
      bindCollides =
        listenAddress == endpoint.address
        || isWildcardAddress listenAddress
        || isWildcardAddress endpoint.address;
    in
    [
      {
        assertion = !tailscaleCfg.enable || config.alanix.tailscale.enable;
        message = "${optionPrefix}.tailscale requires alanix.tailscale.enable = true.";
      }
      {
        assertion =
          !tailscaleCfg.enable
          || config.services.tailscale.interfaceName != "userspace-networking";
        message = "${optionPrefix}.tailscale does not support services.tailscale.interfaceName = \"userspace-networking\".";
      }
      {
        assertion = !tailscaleCfg.enable || tailscaleCfg.port != null;
        message = "${optionPrefix}.tailscale.port must be set explicitly when Tailscale exposure is enabled.";
      }
      {
        assertion =
          !tailscaleCfg.enable
          || !portCollides
          || !bindCollides;
        message = "${optionPrefix}.tailscale would collide with the service's own listen address/port; keep the service internal or choose a different Tailscale address/port.";
      }
      {
        assertion = !tailscaleCfg.enable || !tailscaleCfg.tls || isHttpEndpoint endpoint;
        message = "${optionPrefix}.tailscale.tls only supports HTTP/HTTPS services.";
      }
      {
        assertion =
          !tailscaleCfg.enable
          || !tailscaleCfg.tls
          || tailscaleCfg.tlsName != null
          || tailscaleCfg.address != null;
        message = "${optionPrefix}.tailscale.tlsName must be set when Tailscale TLS exposure is enabled without an explicit address.";
      }
    ];

  mkConfig =
    {
      config,
      serviceName,
      serviceDescription ? serviceName,
      endpoint,
      tailscaleCfg,
    }:
    lib.mkIf tailscaleCfg.enable (
      let
        listenAddress = effectiveListenAddress tailscaleCfg;
        listenPort =
          if tailscaleCfg.port != null then
            tailscaleCfg.port
          else
            endpoint.port;
        tlsName =
          if tailscaleCfg.tlsName != null then
            tailscaleCfg.tlsName
          else
            listenAddress;
        upstream = mkUpstream endpoint;
        interfaceName = config.services.tailscale.interfaceName;
        socketProxyName = "alanix-expose-tailscale-${serviceName}";
      in
      lib.mkMerge [
        {
          networking.firewall.interfaces.${interfaceName}.allowedTCPPorts = [ listenPort ];
        }

        (lib.mkIf tailscaleCfg.tls {
          services.caddy.enable = true;
          services.caddy.virtualHosts."alanix-tailscale-${serviceName}" = {
            hostName = "https://${tlsName}:${toString listenPort}";
            listenAddresses = lib.optionals (listenAddress != "0.0.0.0") [ listenAddress ];
            extraConfig = ''
              tls internal
              reverse_proxy ${upstream}
            '';
          };

          systemd.services.caddy.after = [ "alanix-tailscale-ready.service" ];
          systemd.services.caddy.wants = [ "alanix-tailscale-ready.service" ];
        })

        (lib.mkIf (!tailscaleCfg.tls) (
          let
            proxyCfg = mkSocketProxy {
              name = socketProxyName;
              description = "Tailscale exposure for ${serviceDescription}";
              inherit listenAddress listenPort;
              upstreamAddress = endpoint.address;
              upstreamPort = endpoint.port;
              bindToDevice = interfaceName;
              freeBind = true;
            };
            deviceUnit = "sys-subsystem-net-devices-${interfaceName}.device";
          in
          lib.mkMerge [
            proxyCfg
            {
              systemd.sockets.${socketProxyName} = {
                # Start when the tailscale interface appears, not at boot.
                # This avoids a 90s hang when tailscale isn't up yet, and
                # auto-starts the socket whenever tailscale connects (even
                # if it wasn't available at boot).
                wantedBy = lib.mkForce [ deviceUnit ];
                after = [ "alanix-tailscale-ready.service" deviceUnit ];
                bindsTo = [ deviceUnit ];
              };
              systemd.services.${socketProxyName} = {
                after = [ "alanix-tailscale-ready.service" ];
                wants = [ "alanix-tailscale-ready.service" ];
              };
            }
          ]
        ))
      ]
    );
}
