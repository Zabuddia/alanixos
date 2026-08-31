{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.realtime;
in
{
  options.alanix.realtime = {
    enable = lib.mkEnableOption "shared Prosody and TURN runtime infrastructure";

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/alanix-realtime";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    turn = {
      hostName = lib.mkOption {
        type = lib.types.str;
        default = "turn.fifefin.com";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3479;
      };
      tlsPort = lib.mkOption {
        type = lib.types.port;
        default = 5349;
      };
      relayMinPort = lib.mkOption {
        type = lib.types.port;
        default = 49160;
      };
      relayMaxPort = lib.mkOption {
        type = lib.types.port;
        default = 49200;
      };
    };

    acme = {
      dnsProvider = lib.mkOption {
        type = lib.types.str;
        default = "cloudflare";
      };
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = "Environment file containing credentials for the ACME DNS provider.";
      };
    };

    cluster = {
      enable = lib.mkEnableOption "cluster management for the realtime runtime";
      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "12h";
      };
      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "24h";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.stateDir;
        message = "alanix.realtime.stateDir must be absolute.";
      }
      {
        assertion = cfg.turn.relayMinPort <= cfg.turn.relayMaxPort;
        message = "alanix.realtime.turn.relayMinPort must not exceed relayMaxPort.";
      }
      {
        assertion = !cfg.cluster.enable || cfg.backupDir != null;
        message = "alanix.realtime.cluster.enable requires alanix.realtime.backupDir.";
      }
      {
        assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
        message = "alanix.realtime.backupDir must be absolute.";
      }
    ];

    services.prosody.enable = true;

    security.acme.acceptTerms = lib.mkDefault true;
    security.acme.certs.${cfg.turn.hostName} = {
      dnsProvider = cfg.acme.dnsProvider;
      environmentFile = cfg.acme.credentialsFile;
      group = "turnserver";
      reloadServices = [ "coturn.service" ];
    };

    services.coturn = {
      enable = true;
      listening-port = cfg.turn.port;
      tls-listening-port = cfg.turn.tlsPort;
      min-port = cfg.turn.relayMinPort;
      max-port = cfg.turn.relayMaxPort;
      use-auth-secret = true;
      static-auth-secret-file = "${cfg.stateDir}/turn-secret";
      realm = cfg.turn.hostName;
      no-tls = false;
      no-dtls = true;
      no-tcp-relay = true;
      no-cli = true;
      cert = "${config.security.acme.certs.${cfg.turn.hostName}.directory}/fullchain.pem";
      pkey = "${config.security.acme.certs.${cfg.turn.hostName}.directory}/key.pem";
      extraConfig = ''
        fingerprint
        stale-nonce=600
        no-multicast-peers
      '';
    };

    systemd.tmpfiles.rules = [
      # The files remain group-restricted, but both the prosody and turnserver
      # users need to traverse this neutral shared state directory.
      "d ${cfg.stateDir} 0755 root root - -"
    ];

    systemd.services.alanix-realtime-init = {
      description = "Initialize shared Prosody/TURN credentials";
      before = [ "prosody.service" "coturn.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        secret_file=${lib.escapeShellArg "${cfg.stateDir}/turn-secret"}
        environment_file=${lib.escapeShellArg "${cfg.stateDir}/environment"}

        if [ ! -s "$secret_file" ]; then
          ${lib.getExe' pkgs.coreutils "tr"} -dc a-zA-Z0-9 </dev/urandom \
            | ${lib.getExe' pkgs.coreutils "head"} -c 64 > "$secret_file"
        fi
        chown root:turnserver "$secret_file"
        chmod 0640 "$secret_file"

        printf 'TURN_SECRET=%s\n' "$(cat "$secret_file")" > "$environment_file"
        chown root:prosody "$environment_file"
        chmod 0640 "$environment_file"
      '';
    };

    systemd.services.prosody = {
      requires = [ "alanix-realtime-init.service" ];
      after = [ "alanix-realtime-init.service" ];
      serviceConfig.EnvironmentFile = [ "${cfg.stateDir}/environment" ];
    };

    systemd.services.coturn = {
      requires = [ "alanix-realtime-init.service" ];
      after = [ "alanix-realtime-init.service" "acme-${cfg.turn.hostName}.service" ];
      wants = [ "acme-${cfg.turn.hostName}.service" ];
      preStart = lib.mkAfter ''
        public_address="$(${lib.getExe pkgs.getent} ahostsv4 ${lib.escapeShellArg cfg.turn.hostName} \
          | ${lib.getExe pkgs.gawk} 'NR == 1 { print $1; exit }')"

        # A newly promoted node can start before cluster DDNS has created or
        # refreshed the TURN record, and a local resolver may retain the
        # resulting negative answer. Use the same public-IP source as cluster
        # DDNS as the bootstrap fallback instead of coupling coturn startup to
        # DNS propagation.
        if [ -z "$public_address" ]; then
          public_address="$(${lib.getExe pkgs.curl} --ipv4 --fail --silent --show-error \
            https://cloudflare.com/cdn-cgi/trace \
            | ${lib.getExe pkgs.gawk} -F= '$1 == "ip" { print $2; exit }')"
        fi
        if ! [[ "$public_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          echo "Unable to determine the public IPv4 address for TURN." >&2
          exit 1
        fi
        printf 'external-ip=%s\n' "$public_address" >> /run/coturn/turnserver.cfg
      '';
    };

    networking.firewall.allowedUDPPorts = [ cfg.turn.port ];
    networking.firewall.allowedTCPPorts = [ cfg.turn.port cfg.turn.tlsPort ];
    networking.firewall.allowedUDPPortRanges = [
      { from = cfg.turn.relayMinPort; to = cfg.turn.relayMaxPort; }
    ];
  };
}
