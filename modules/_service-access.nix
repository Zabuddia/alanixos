{ lib }:
{
  mkBackendFirewallOptions =
    {
      serviceTitle,
      defaultOpenFirewall ? false,
    }:
    {
      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = defaultOpenFirewall;
        description = "Open the direct ${serviceTitle} backend port in the firewall.";
      };

      firewallInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Optional interface allowlist for the direct ${serviceTitle} backend port.
          Empty means open globally via networking.firewall.allowedTCPPorts.
        '';
      };
    };

  mkWanAccessOptions = { serviceTitle }:
    {
      enable = lib.mkEnableOption "WAN/public access path for ${serviceTitle} via Caddy";

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public DNS name served by Caddy for ${serviceTitle}.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open TCP 80/443 for Caddy when WAN access is enabled.";
      };
    };

  mkClusterAccessOptions =
    {
      serviceTitle,
      defaultPort,
      defaultInterface ? "tailscale0",
    }:
    {
      enable = lib.mkEnableOption "private cluster-only access path for ${serviceTitle}";

      listenAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Private cluster-side address to bind for internal access.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = defaultPort;
        description = "Private cluster-only Caddy listener port.";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = defaultInterface;
        description = "Firewall interface for private cluster-only access.";
      };
    };

  mkTorAccessOptions =
    {
      serviceTitle,
      defaultServiceName,
      defaultHttpLocalPort,
      defaultHttpsLocalPort,
      defaultHttpVirtualPort ? 80,
      defaultHttpsVirtualPort ? 443,
    }:
    {
      enable = lib.mkEnableOption "Tor onion-service access path for ${serviceTitle}";

      serviceName = lib.mkOption {
        type = lib.types.str;
        default = defaultServiceName;
        description = "Tor onion service name key under services.tor.relay.onionServices.";
      };

      enableHttp = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Expose plaintext HTTP over Tor for this service.";
      };

      httpLocalPort = lib.mkOption {
        type = lib.types.port;
        default = defaultHttpLocalPort;
        description = "Local Caddy HTTP listener used as Tor hidden-service backend.";
      };

      httpVirtualPort = lib.mkOption {
        type = lib.types.port;
        default = defaultHttpVirtualPort;
        description = "Virtual onion HTTP port exposed to Tor clients.";
      };

      enableHttps = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Expose HTTPS over Tor for this service.";
      };

      httpsLocalPort = lib.mkOption {
        type = lib.types.port;
        default = defaultHttpsLocalPort;
        description = "Local Caddy HTTPS listener used as Tor hidden-service backend.";
      };

      httpsVirtualPort = lib.mkOption {
        type = lib.types.port;
        default = defaultHttpsVirtualPort;
        description = "Virtual onion HTTPS port exposed to Tor clients.";
      };

      version = lib.mkOption {
        type = lib.types.enum [ 2 3 ];
        default = 3;
        description = "Tor hidden-service version.";
      };

      secretKeySecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional sops secret containing a Tor hidden-service secret key for stable onion address.";
      };
    };

  mkAccessAssertions =
    {
      cfg,
      modulePathPrefix,
      hasSopsSecrets,
    }:
    [
      {
        assertion = !(cfg.wanAccess.enable && cfg.wanAccess.domain == null);
        message = "${modulePathPrefix}.wanAccess.domain must be set when wanAccess is enabled.";
      }
      {
        assertion = !(cfg.clusterAccess.enable && cfg.clusterAccess.listenAddress == null);
        message = "${modulePathPrefix}.clusterAccess.listenAddress must be set when clusterAccess is enabled.";
      }
      {
        assertion = !(cfg.torAccess.enable && cfg.torAccess.secretKeySecret != null && !hasSopsSecrets);
        message = "${modulePathPrefix}.torAccess.secretKeySecret requires sops-nix configuration.";
      }
      {
        assertion = !(cfg.torAccess.enable && !(cfg.torAccess.enableHttp || cfg.torAccess.enableHttps));
        message = "${modulePathPrefix}.torAccess.enable requires at least one of torAccess.enableHttp or torAccess.enableHttps.";
      }
      {
        assertion = !(cfg.torAccess.enable && cfg.torAccess.enableHttp && cfg.torAccess.enableHttps && cfg.torAccess.httpLocalPort == cfg.torAccess.httpsLocalPort);
        message = "${modulePathPrefix}.torAccess.httpLocalPort and torAccess.httpsLocalPort must differ when both HTTP and HTTPS Tor access are enabled.";
      }
      {
        assertion = !(cfg.torAccess.enable && cfg.torAccess.enableHttp && cfg.torAccess.enableHttps && cfg.torAccess.httpVirtualPort == cfg.torAccess.httpsVirtualPort);
        message = "${modulePathPrefix}.torAccess.httpVirtualPort and torAccess.httpsVirtualPort must differ when both HTTP and HTTPS Tor access are enabled.";
      }
    ];

  mkAccessFirewallConfig = { cfg }:
    lib.mkMerge [
      (lib.mkIf (cfg.active && cfg.openFirewall && cfg.firewallInterfaces == []) {
        allowedTCPPorts = [ cfg.port ];
      })
      (lib.mkIf (cfg.active && cfg.openFirewall && cfg.firewallInterfaces != []) {
        interfaces =
          lib.genAttrs cfg.firewallInterfaces (_: { allowedTCPPorts = [ cfg.port ]; });
      })
      (lib.mkIf (cfg.wanAccess.enable && cfg.wanAccess.openFirewall) {
        allowedTCPPorts = [ 80 443 ];
      })
      (lib.mkIf cfg.clusterAccess.enable {
        interfaces =
          lib.genAttrs [ cfg.clusterAccess.interface ] (_: { allowedTCPPorts = [ cfg.clusterAccess.port ]; });
      })
    ];

  mkAccessCaddyConfig = { cfg, upstreamPort }:
    lib.mkIf (cfg.wanAccess.enable || cfg.clusterAccess.enable || cfg.torAccess.enable) {
      enable = true;
      virtualHosts = lib.mkMerge [
        (lib.mkIf cfg.wanAccess.enable {
          "${cfg.wanAccess.domain}".extraConfig = ''
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString upstreamPort}
          '';
        })
        (lib.mkIf cfg.clusterAccess.enable {
          "http://${cfg.clusterAccess.listenAddress}:${toString cfg.clusterAccess.port}".extraConfig = ''
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString upstreamPort}
          '';
        })
        (lib.mkIf (cfg.torAccess.enable && cfg.torAccess.enableHttp) {
          "http://*.onion:${toString cfg.torAccess.httpLocalPort}".extraConfig = ''
            bind 127.0.0.1
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString upstreamPort}
          '';
        })
        (lib.mkIf (cfg.torAccess.enable && cfg.torAccess.enableHttps) {
          "https://*.onion:${toString cfg.torAccess.httpsLocalPort}".extraConfig = ''
            bind 127.0.0.1
            tls internal
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString upstreamPort}
          '';
        })
      ];
    };

  mkTorConfig = { cfg, torSecretKeyPath }:
    lib.mkIf cfg.torAccess.enable {
      enable = true;
      relay.onionServices.${cfg.torAccess.serviceName} =
        {
          version = cfg.torAccess.version;
          map =
            (lib.optionals cfg.torAccess.enableHttp [
              {
                port = cfg.torAccess.httpVirtualPort;
                target = {
                  addr = "127.0.0.1";
                  port = cfg.torAccess.httpLocalPort;
                };
              }
            ])
            ++ (lib.optionals cfg.torAccess.enableHttps [
              {
                port = cfg.torAccess.httpsVirtualPort;
                target = {
                  addr = "127.0.0.1";
                  port = cfg.torAccess.httpsLocalPort;
                };
              }
            ]);
        }
        // lib.optionalAttrs (torSecretKeyPath != null) {
          secretKey = torSecretKeyPath;
        };
    };
}
