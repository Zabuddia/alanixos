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

  jicofoReadyScript = pkgs.writeShellScript "alanix-jicofo-wait-ready" ''
    set -eu

    attempts=60
    while ! ${lib.getExe pkgs.curl} --fail --silent --show-error \
      "http://127.0.0.1:${toString cfg.jicofo.restPort}/about/version" >/dev/null 2>&1; do
      attempts=$((attempts - 1))
      if [ "$attempts" -eq 0 ]; then
        echo "Timed out waiting for Jicofo's REST API." >&2
        exit 1
      fi
      ${lib.getExe' pkgs.coreutils "sleep"} 1
    done

    # The REST listener starts just before Jicofo joins its XMPP brewery.
    # Keep the unit activating briefly so Videobridge cannot create that room first.
    ${lib.getExe' pkgs.coreutils "sleep"} 2
  '';

  videobridgeReadyScript = pkgs.writeShellScript "alanix-jitsi-videobridge-wait-ready" ''
    set -eu

    attempts=60
    while ! ${lib.getExe pkgs.curl} --fail --silent --show-error \
      "http://127.0.0.1:${toString cfg.videobridge.privateHttpPort}/about/version" >/dev/null 2>&1; do
      attempts=$((attempts - 1))
      if [ "$attempts" -eq 0 ]; then
        echo "Timed out waiting for Jitsi Videobridge's private HTTP API." >&2
        exit 1
      fi
      ${lib.getExe' pkgs.coreutils "sleep"} 1
    done
  '';
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

    jicofo.restPort = lib.mkOption {
      type = lib.types.port;
      default = 8889;
      description = "Loopback port used by Jicofo's internal REST API.";
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
      privateHttpPort = lib.mkOption {
        type = lib.types.port;
        default = 9091;
        description = "Loopback port used by Jitsi Videobridge's private HTTP API.";
      };

      allowedAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Local addresses from which Videobridge may gather ICE candidates.
          An empty list allows every address on every active interface.
        '';
      };

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

    turn = {
      enable = lib.mkEnableOption "a coturn relay for clients that cannot reach Videobridge directly";

      hostName = lib.mkOption {
        type = lib.types.str;
        default = cfg.hostName;
        defaultText = "alanix.jitsi-meet.hostName";
        description = "Public hostname advertised for the STUN and TURN services.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3478;
        description = "Public UDP and TCP port for STUN and TURN.";
      };

      relayMinPort = lib.mkOption {
        type = lib.types.port;
        default = 49160;
        description = "First UDP port available for TURN relay allocations.";
      };

      relayMaxPort = lib.mkOption {
        type = lib.types.port;
        default = 49200;
        description = "Last UDP port available for TURN relay allocations.";
      };

      secretFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/jitsi-meet/turn-secret";
        description = "Persistent TURN REST authentication secret shared by Prosody and coturn.";
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
          {
            assertion = !cfg.turn.enable || lib.hasPrefix "/" cfg.turn.secretFile;
            message = "alanix.jitsi-meet.turn.secretFile must be an absolute path.";
          }
          {
            assertion = !cfg.turn.enable || cfg.turn.relayMinPort <= cfg.turn.relayMaxPort;
            message = "alanix.jitsi-meet.turn.relayMinPort must not exceed relayMaxPort.";
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
          extraProperties = lib.optionalAttrs (cfg.videobridge.allowedAddresses != [ ]) {
            "org.ice4j.ice.harvest.ALLOWED_ADDRESSES" =
              lib.concatStringsSep ";" cfg.videobridge.allowedAddresses;
          };
          config.videobridge = {
            http-servers.private = {
              host = "127.0.0.1";
              port = cfg.videobridge.privateHttpPort;
            };
            ice = {
              udp.port = cfg.videobridge.udpPort;
              tcp = {
                enabled = cfg.videobridge.tcpFallback.enable;
                port = cfg.videobridge.tcpFallback.port;
              };
            };
          };
          nat = {
            inherit (cfg.videobridge.nat) localAddress publicAddress harvesterAddresses;
          };
        };

        services.jicofo.config.jicofo.rest = {
          host = "127.0.0.1";
          port = cfg.jicofo.restPort;
        };

        # Current Videobridge releases only advertise UDP ICE candidates.
        # Coturn provides an authenticated TCP path for restrictive client networks.
        services.coturn = lib.mkIf cfg.turn.enable {
          enable = true;
          listening-port = cfg.turn.port;
          min-port = cfg.turn.relayMinPort;
          max-port = cfg.turn.relayMaxPort;
          use-auth-secret = true;
          static-auth-secret-file = cfg.turn.secretFile;
          realm = cfg.turn.hostName;
          no-tls = true;
          no-dtls = true;
          no-tcp-relay = true;
          no-cli = true;
          extraConfig = ''
            fingerprint
            stale-nonce=600
            no-multicast-peers
          '';
        };

        users.groups.jitsi-meet.members = lib.optionals cfg.turn.enable [ "turnserver" ];

        services.prosody.virtualHosts.${cfg.hostName}.extraConfig = lib.mkIf cfg.turn.enable (lib.mkAfter ''
          -- NixOS validates this configuration in the build sandbox, where
          -- runtime secrets do not exist. Prosody receives TURN_SECRET from
          -- Jitsi's secrets-env file when the service actually starts.
          external_service_secret = os.getenv("TURN_SECRET") or "prosody-config-validation-only"
          external_services = {
            { type = "stun"; transport = "udp"; host = "${cfg.turn.hostName}"; port = ${toString cfg.turn.port}; };
            { type = "turn"; transport = "udp"; host = "${cfg.turn.hostName}"; port = ${toString cfg.turn.port}; secret = true; };
            { type = "turn"; transport = "tcp"; host = "${cfg.turn.hostName}"; port = ${toString cfg.turn.port}; secret = true; };
          }
        '');

        # Jicofo and Videobridge are local service accounts which reconnect on
        # their own. Disabling stream resumption prevents a stopped bridge's
        # old XMPP resource from lingering and receiving health checks.
        services.prosody.virtualHosts."auth.${cfg.hostName}".extraConfig = lib.mkAfter ''
          modules_disabled = { "smacks" }
        '';

        systemd.services = {
          jitsi-meet-init-secrets = lib.mkIf cfg.turn.enable {
            before = [ "coturn.service" ];
            script = lib.mkAfter ''
              if [ ! -f ${lib.escapeShellArg cfg.turn.secretFile} ]; then
                ${lib.getExe' pkgs.coreutils "tr"} -dc a-zA-Z0-9 </dev/urandom \
                  | ${lib.getExe' pkgs.coreutils "head"} -c 64 > ${lib.escapeShellArg cfg.turn.secretFile}
                chmod 0640 ${lib.escapeShellArg cfg.turn.secretFile}
              fi

              printf 'TURN_SECRET=%s\n' "$(cat ${lib.escapeShellArg cfg.turn.secretFile})" \
                >> /var/lib/jitsi-meet/secrets-env
            '';
          };

          # Prosody does not unload host modules such as mod_smacks on a config
          # reload. Restart it so changes to the Jitsi XMPP hosts take effect
          # and in-memory sessions from stopped service accounts are cleared.
          prosody = {
            reloadIfChanged = lib.mkForce false;
            after = lib.optionals cfg.turn.enable [ "jitsi-meet-init-secrets.service" ];
            requires = lib.optionals cfg.turn.enable [ "jitsi-meet-init-secrets.service" ];
            preStart = lib.mkIf cfg.turn.enable (lib.mkAfter ''
              if [ -z "''${TURN_SECRET:-}" ]; then
                echo "TURN_SECRET is missing from Jitsi's runtime environment." >&2
                exit 1
              fi
            '');
          };

          jicofo = {
            after = [ "prosody.service" ];
            requires = [ "prosody.service" ];
            serviceConfig.ExecStartPost = [ jicofoReadyScript ];
          };

          jitsi-videobridge2 = {
            after = [
              "prosody.service"
              "jicofo.service"
            ];
            requires = [
              "prosody.service"
              "jicofo.service"
            ];
            serviceConfig.ExecStartPost = [ videobridgeReadyScript ];
          };

          coturn = lib.mkIf cfg.turn.enable {
            after = [ "jitsi-meet-init-secrets.service" ];
            requires = [ "jitsi-meet-init-secrets.service" ];
            preStart = lib.mkAfter ''
              public_address="$(${lib.getExe pkgs.getent} ahostsv4 ${lib.escapeShellArg cfg.turn.hostName} \
                | ${lib.getExe pkgs.gawk} 'NR == 1 { print $1; exit }')"
              if [ -z "$public_address" ]; then
                echo "Unable to resolve an IPv4 address for ${cfg.turn.hostName}." >&2
                exit 1
              fi
              printf 'external-ip=%s\n' "$public_address" >> /run/coturn/turnserver.cfg
            '';
            serviceConfig.SupplementaryGroups = [ "jitsi-meet" ];
          };
        };

        networking.firewall.allowedUDPPorts =
          lib.optionals cfg.videobridge.openFirewall [ cfg.videobridge.udpPort ]
          ++ lib.optionals cfg.turn.enable [ cfg.turn.port ];
        networking.firewall.allowedUDPPortRanges = lib.optionals cfg.turn.enable [
          {
            from = cfg.turn.relayMinPort;
            to = cfg.turn.relayMaxPort;
          }
        ];
        networking.firewall.allowedTCPPorts =
          lib.optionals (cfg.videobridge.openFirewall && cfg.videobridge.tcpFallback.enable) [
            cfg.videobridge.tcpFallback.port
          ]
          ++ lib.optionals cfg.turn.enable [ cfg.turn.port ];
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
