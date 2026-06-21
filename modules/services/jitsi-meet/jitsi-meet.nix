{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.alanix.jitsi-meet;
  clusterCfg = cfg.cluster;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  exposeCfg = cfg.expose;
  endpoint = {
    address = cfg.listenAddress;
    port = cfg.port;
    protocol = "http";
  };
in
{
  options.alanix.jitsi-meet = {
    enable = lib.mkEnableOption "Jitsi Meet (Alanix)";

    hostName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.fqdnOrHostName;
      defaultText = "config.networking.fqdnOrHostName";
      description = "Public hostname used by the Jitsi web and XMPP services.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Internal address on which the Jitsi web frontend listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8095;
      description = "Internal HTTP port for the Jitsi web frontend.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    config = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Jitsi Meet client settings merged into config.js.";
    };

    interfaceConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Jitsi Meet client interface settings merged into interface_config.js.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "JavaScript appended to the generated Jitsi Meet config.js.";
    };

    prosody.lockdown = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Restrict the bundled Prosody server to Jitsi's local-only requirements.";
    };

    secureDomain = {
      enable = lib.mkEnableOption "authenticated Jitsi room creation";

      authentication = lib.mkOption {
        type = lib.types.str;
        default = "internal_hashed";
        description = "Prosody authentication backend used for authenticated room creation.";
      };
    };

    excalidraw = {
      enable = lib.mkEnableOption "the Jitsi Excalidraw collaborative whiteboard backend";

      port = lib.mkOption {
        type = lib.types.port;
        default = 3002;
        description = "Local port for the Excalidraw collaboration backend.";
      };
    };

    videobridge = {
      udpPort = lib.mkOption {
        type = lib.types.port;
        default = 10000;
        description = "UDP port used for WebRTC media traffic.";
      };

      tcpFallback = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable the Videobridge TCP ICE fallback listener.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 4443;
          description = "TCP port used as a fallback for WebRTC media traffic.";
        };
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open the Videobridge UDP and optional TCP media ports in the host firewall.";
      };

      nat = {
        localAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional local address advertised by Videobridge when behind NAT.";
        };

        publicAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional public address advertised by Videobridge when behind NAT.";
        };

        harvesterAddresses = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "stunserver.stunprotocol.org:3478"
            "stun.framasoft.org:3478"
            "meet-jit-si-turnrelay.jitsi.net:443"
          ];
          description = "STUN services used to discover NAT addresses when explicit addresses are not set.";
        };
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "jitsi-meet";
      serviceDescription = "Jitsi Meet";
      defaultPublicPort = 443;
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-managed Jitsi Meet";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "How often the active node backs up Jitsi and Prosody identity state.";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "6h";
        description = "Maximum acceptable Jitsi backup age for normal failover.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Jitsi Meet 1.0.8792 still ships libolm for optional end-to-end
        # encryption. Keep this exception version-specific so a nixpkgs update
        # requires the warning to be reviewed again.
        nixpkgs.config.permittedInsecurePackages = [ "jitsi-meet-1.0.8792" ];

        assertions = [
          {
            assertion = cfg.hostName != "";
            message = "alanix.jitsi-meet.hostName must be set when Jitsi Meet is enabled.";
          }
          {
            assertion = cfg.listenAddress != "";
            message = "alanix.jitsi-meet.listenAddress must be set when Jitsi Meet is enabled.";
          }
          {
            assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
            message = "alanix.jitsi-meet.backupDir must be an absolute path when set.";
          }
          {
            assertion = !clusterCfg.enable || cfg.backupDir != null;
            message = "alanix.jitsi-meet.cluster.enable requires alanix.jitsi-meet.backupDir to be set.";
          }
          {
            assertion =
              (cfg.videobridge.nat.localAddress == null) == (cfg.videobridge.nat.publicAddress == null);
            message = "alanix.jitsi-meet.videobridge.nat.localAddress and publicAddress must be set together.";
          }
          {
            assertion = !exposeCfg.wan.enable || exposeCfg.wan.domain == cfg.hostName;
            message = "alanix.jitsi-meet.expose.wan.domain must match alanix.jitsi-meet.hostName.";
          }
        ]
        ++ serviceExposure.mkAssertions {
          inherit config endpoint exposeCfg;
          optionPrefix = "alanix.jitsi-meet.expose";
        };

        services.jitsi-meet = {
          enable = true;
          hostName = cfg.hostName;
          nginx.enable = true;
          caddy.enable = false;
          prosody.lockdown = cfg.prosody.lockdown;
          secureDomain = {
            inherit (cfg.secureDomain) enable authentication;
          };
          excalidraw = {
            inherit (cfg.excalidraw) enable port;
          };
          inherit (cfg) config interfaceConfig extraConfig;
        };

        services.nginx.virtualHosts.${cfg.hostName} = {
          enableACME = lib.mkForce false;
          forceSSL = lib.mkForce false;
          listen = [
            {
              addr = cfg.listenAddress;
              port = cfg.port;
              ssl = false;
            }
          ];
        };

        services.jitsi-videobridge = {
          openFirewall = false;
          config.videobridge.ice = {
            udp.port = cfg.videobridge.udpPort;
            tcp = {
              enabled = cfg.videobridge.tcpFallback.enable;
              port = cfg.videobridge.tcpFallback.port;
            };
          };
          nat = {
            inherit (cfg.videobridge.nat) localAddress publicAddress harvesterAddresses;
          };
        };

        networking.firewall.allowedUDPPorts = lib.optionals cfg.videobridge.openFirewall [
          cfg.videobridge.udpPort
        ];
        networking.firewall.allowedTCPPorts = lib.optionals (
          cfg.videobridge.openFirewall && cfg.videobridge.tcpFallback.enable
        ) [ cfg.videobridge.tcpFallback.port ];
      }

      (lib.mkIf (!clusterCfg.enable) (
        serviceExposure.mkConfig {
          inherit config endpoint exposeCfg;
          serviceName = "jitsi-meet";
          serviceDescription = "Jitsi Meet";
        }
      ))
    ]
  );
}
