{ lib, pkgs }:
let
  types = lib.types;
  backends = import ../modules/expose { inherit lib pkgs; };
in
{
  mkOptions =
    {
      serviceName,
      serviceDescription,
      defaultPublicPort ? 80,
    }:
    {
      tailscale = {
        enable = lib.mkEnableOption "expose ${serviceDescription} on Tailscale";

        address = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Tailscale-facing bind address. Defaults to 0.0.0.0, which typically
            means you should choose a port different from the service's local
            listen port unless you set this to the host's Tailscale IP.
          '';
        };

        port = lib.mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "Tailscale-facing port. Must be set explicitly when Tailscale exposure is enabled.";
        };

        tls = lib.mkOption {
          type = types.bool;
          default = false;
          description = "Whether to terminate HTTPS with a private/self-signed certificate on the Tailscale listener.";
        };

        tlsName = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Hostname or IP address presented by the HTTPS certificate. Defaults to the Tailscale bind address.";
        };
      };

      tor = {
        enable = lib.mkEnableOption "expose ${serviceDescription} as a Tor onion service";

        onionServiceName = lib.mkOption {
          type = types.str;
          default = serviceName;
          description = "Attribute name used under services.tor.relay.onionServices.";
        };

        publicPort = lib.mkOption {
          type = types.port;
          default = defaultPublicPort;
          description = "Port exposed by the onion service.";
        };

        targetAddress = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Override the service endpoint address used for Tor forwarding.";
        };

        secretKeyBase64Secret = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Name of the sops secret containing the base64-encoded Tor v3
            hs_ed25519_secret_key file. When omitted, Tor generates and persists
            a key in its normal state directory.
          '';
        };

        tls = lib.mkOption {
          type = types.bool;
          default = false;
          description = "Whether to terminate HTTPS with a private/self-signed certificate before forwarding to the service.";
        };

        tlsName = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Hostname presented by the HTTPS certificate when Tor TLS exposure is enabled.
            Set this to the onion hostname clients will visit.
          '';
        };
      };

      wireguard = {
        enable = lib.mkEnableOption "expose ${serviceDescription} on the WireGuard interface";

        address = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "WireGuard-facing bind address. Defaults to alanix.wireguard.vpnIP.";
        };

        port = lib.mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "WireGuard-facing port. Must be set explicitly when WireGuard exposure is enabled.";
        };

        tls = lib.mkOption {
          type = types.bool;
          default = false;
          description = "Whether to terminate HTTPS with a private/self-signed certificate on the WireGuard listener.";
        };

        tlsName = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Hostname or IP address presented by the HTTPS certificate. Defaults to the WireGuard bind address.";
        };
      };

      wan = {
        enable = lib.mkEnableOption "expose ${serviceDescription} on the public WAN";

        address = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "WAN-facing bind address. Defaults to 0.0.0.0.";
        };

        domain = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Public domain for HTTP/HTTPS WAN exposure.";
        };

        port = lib.mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "WAN-facing port. Defaults to 80/443 for HTTP(S), or the service endpoint port for TCP.";
        };

        tls = lib.mkOption {
          type = types.bool;
          default = true;
          description = "Whether WAN HTTP exposure should use TLS termination.";
        };
      };
    };

  mkAssertions =
    {
      config,
      optionPrefix,
      endpoint,
      exposeCfg,
    }:
    backends.tailscale.mkAssertions {
      inherit config optionPrefix endpoint;
      tailscaleCfg = exposeCfg.tailscale;
    }
    ++ backends.tor.mkAssertions {
      inherit config optionPrefix endpoint;
      torCfg = exposeCfg.tor;
    }
    ++ backends.wireguard.mkAssertions {
      inherit config optionPrefix endpoint;
      wireguardCfg = exposeCfg.wireguard;
    }
    ++ backends.wan.mkAssertions {
      inherit config optionPrefix endpoint;
      wanCfg = exposeCfg.wan;
    };

  mkConfig =
    {
      serviceName,
      serviceDescription ? serviceName,
      config,
      endpoint,
      exposeCfg,
    }:
    lib.mkMerge [
      (backends.tailscale.mkConfig {
        inherit config serviceName serviceDescription endpoint;
        tailscaleCfg = exposeCfg.tailscale;
      })
      (backends.tor.mkConfig {
        inherit config serviceName serviceDescription endpoint;
        torCfg = exposeCfg.tor;
      })
      (backends.wireguard.mkConfig {
        inherit config serviceName serviceDescription endpoint;
        wireguardCfg = exposeCfg.wireguard;
      })
      (backends.wan.mkConfig {
        inherit serviceName serviceDescription endpoint;
        wanCfg = exposeCfg.wan;
      })
    ];
}
