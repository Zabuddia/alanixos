{ lib, pkgs }:
let
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
      torCfg,
    }:
    let
      targetAddress =
        if torCfg.targetAddress != null then
          torCfg.targetAddress
        else
          normalizeLocalAddress endpoint.address;
    in
    [
      {
        assertion = !torCfg.enable || builtins.match "^[A-Za-z0-9._-]+$" torCfg.onionServiceName != null;
        message = "${optionPrefix}.tor.onionServiceName may contain only letters, digits, dot, underscore, and hyphen.";
      }
      {
        assertion =
          !torCfg.enable
          || torCfg.secretKeyBase64Secret == null
          || lib.hasAttrByPath [ "sops" "secrets" torCfg.secretKeyBase64Secret ] config;
        message = "${optionPrefix}.tor.secretKeyBase64Secret must reference a declared sops secret.";
      }
      {
        assertion = !torCfg.enable || endpoint.port != null;
        message = "${optionPrefix}.tor requires a concrete service endpoint port.";
      }
      {
        assertion = !torCfg.enable || !torCfg.tls || isHttpEndpoint endpoint;
        message = "${optionPrefix}.tor.tls only supports HTTP/HTTPS services.";
      }
      {
        assertion = !torCfg.enable || !torCfg.tls || torCfg.tlsName != null;
        message = "${optionPrefix}.tor.tlsName must be set when Tor TLS exposure is enabled.";
      }
      {
        assertion =
          !torCfg.enable
          || !torCfg.tls
          || targetAddress != endpoint.address
          || torCfg.publicPort != endpoint.port;
        message = "${optionPrefix}.tor.tls would collide with the service's own listen address/port; choose a different Tor target address or public port.";
      }
    ];

  mkConfig =
    {
      config,
      serviceName,
      serviceDescription ? serviceName,
      endpoint,
      torCfg,
    }:
    lib.mkIf torCfg.enable (
      let
        runtimeDirectory = "alanix-${serviceName}-tor";
        decodedKeyPath = "/run/${runtimeDirectory}/hs_ed25519_secret_key";
        secretUnitName = "${serviceName}-tor-secret-key";
        targetAddress =
          if torCfg.targetAddress != null then
            torCfg.targetAddress
          else
            normalizeLocalAddress endpoint.address;
        targetPort = if torCfg.tls then torCfg.publicPort else endpoint.port;
        upstream = mkUpstream endpoint;
      in
      lib.mkMerge [
        {
          services.tor.enable = true;
          services.tor.relay.onionServices.${torCfg.onionServiceName} =
            {
              version = 3;
              map = [
                {
                  port = torCfg.publicPort;
                  target = {
                    addr = targetAddress;
                    port = targetPort;
                  };
                }
              ];
            }
            // lib.optionalAttrs (torCfg.secretKeyBase64Secret != null) {
              secretKey = decodedKeyPath;
            };
        }

        (lib.mkIf torCfg.tls {
          services.caddy.enable = true;
          services.caddy.virtualHosts."alanix-tor-${serviceName}" = {
            hostName = "https://${torCfg.tlsName}:${toString torCfg.publicPort}";
            listenAddresses = [ targetAddress ];
            extraConfig = ''
              tls internal
              reverse_proxy ${upstream}
            '';
          };
        })

        (lib.mkIf (torCfg.secretKeyBase64Secret != null) {
          systemd.services.${secretUnitName} = {
            description = "Decode ${serviceDescription} Tor onion service key";
            before = [ "tor.service" ];
            requiredBy = [ "tor.service" ];
            partOf = [ "tor.service" ];
            after = [ "sops-nix.service" ];
            wants = [ "sops-nix.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              RuntimeDirectory = runtimeDirectory;
              RuntimeDirectoryMode = "0700";
              UMask = "0077";
            };
            path = [ pkgs.coreutils ];
            script = ''
              set -euo pipefail

              base64 --decode ${lib.escapeShellArg config.sops.secrets.${torCfg.secretKeyBase64Secret}.path} > ${lib.escapeShellArg decodedKeyPath}
              chmod 0400 ${lib.escapeShellArg decodedKeyPath}
            '';
          };
        })
      ]
    );
}
