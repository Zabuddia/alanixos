{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.vaultwarden;
  hasSopsSecrets = lib.hasAttrByPath [ "sops" "secrets" ] config;
  torSecretKeyPath =
    if cfg.torAccess.secretKeySecret == null then
      null
    else
      config.sops.secrets.${cfg.torAccess.secretKeySecret}.path;
  vaultwardenSettingsType =
    with lib.types;
    attrsOf (
      nullOr (
        oneOf [
          bool
          int
          str
        ]
      )
    );
in
{
  options.alanix.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden (Alanix)";

    active = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this node actively runs the Vaultwarden service.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8222;
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the direct Vaultwarden backend port in the firewall.";
    };

    firewallInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Optional interface allowlist for the direct Vaultwarden backend port.
        Empty means open globally via networking.firewall.allowedTCPPorts.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/vaultwarden";
      description = "Vaultwarden data directory (must be under /var/lib).";
    };

    uid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned UID for the vaultwarden system user. Set with gid for multi-node consistency.";
    };

    gid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Pinned GID for the vaultwarden system group. Set with uid for multi-node consistency.";
    };

    dbBackend = lib.mkOption {
      type = lib.types.enum [
        "sqlite"
        "mysql"
        "postgresql"
      ];
      default = "sqlite";
      description = "Vaultwarden database backend.";
    };

    settings = lib.mkOption {
      type = vaultwardenSettingsType;
      default = {};
      description = "Additional Vaultwarden environment-style settings.";
    };

    adminTokenSecret = lib.mkOption {
      type = lib.types.str;
      default = "vaultwarden/admin-token";
      description = ''
        Required sops secret path containing raw ADMIN_TOKEN value for Vaultwarden admin access.
      '';
    };

    wanAccess = {
      enable = lib.mkEnableOption "WAN/public access path for Vaultwarden via Caddy";

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public DNS name served by Caddy for Vaultwarden (for example vault.example.com).";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open TCP 80/443 for Caddy when WAN access is enabled.";
      };
    };

    wireguardAccess = {
      enable = lib.mkEnableOption "WireGuard-only access path for Vaultwarden";

      listenAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "WireGuard-side address to bind for internal access (for example 10.100.0.2).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8091;
        description = "WireGuard-only Caddy listener port.";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "wg0";
        description = "Firewall interface for WireGuard-only access.";
      };
    };

    torAccess = {
      enable = lib.mkEnableOption "Tor onion-service access path for Vaultwarden";

      serviceName = lib.mkOption {
        type = lib.types.str;
        default = "vaultwarden";
        description = "Tor onion service name key under services.tor.relay.onionServices.";
      };

      localPort = lib.mkOption {
        type = lib.types.port;
        default = 18222;
        description = "Local Caddy listener used as Tor hidden-service backend.";
      };

      virtualPort = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "Virtual onion service port exposed to Tor clients.";
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.wanAccess.enable && cfg.wanAccess.domain == null);
        message = "alanix.vaultwarden.wanAccess.domain must be set when wanAccess is enabled.";
      }
      {
        assertion = !(cfg.wireguardAccess.enable && cfg.wireguardAccess.listenAddress == null);
        message = "alanix.vaultwarden.wireguardAccess.listenAddress must be set when wireguardAccess is enabled.";
      }
      {
        assertion = !(cfg.torAccess.enable && cfg.torAccess.secretKeySecret != null && !hasSopsSecrets);
        message = "alanix.vaultwarden.torAccess.secretKeySecret requires sops-nix configuration.";
      }
      {
        assertion = hasSopsSecrets;
        message = "alanix.vaultwarden.adminTokenSecret requires sops-nix configuration.";
      }
      {
        assertion = builtins.hasAttr cfg.adminTokenSecret config.sops.secrets;
        message = "alanix.vaultwarden.adminTokenSecret is set but no matching sops.secrets entry exists.";
      }
      {
        assertion = (cfg.uid == null) == (cfg.gid == null);
        message = "alanix.vaultwarden.uid and alanix.vaultwarden.gid must either both be set or both be null.";
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir;
        message = "alanix.vaultwarden.stateDir must be under /var/lib/ so systemd StateDirectory protections keep working.";
      }
    ];

    networking.firewall = lib.mkMerge [
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
      (lib.mkIf cfg.wireguardAccess.enable {
        interfaces =
          lib.genAttrs [ cfg.wireguardAccess.interface ] (_: { allowedTCPPorts = [ cfg.wireguardAccess.port ]; });
      })
    ];

    services.vaultwarden = {
      enable = true;
      dbBackend = cfg.dbBackend;
      backupDir = null;
      configureNginx = false;
      configurePostgres = false;
      environmentFile = [ "/run/alanix-vaultwarden/admin-token.env" ];
      config = {
        ROCKET_ADDRESS = cfg.listenAddress;
        ROCKET_PORT = cfg.port;
        DATA_FOLDER = cfg.stateDir;
        WEBSOCKET_ENABLED = true;
      } // cfg.settings;
    };

    systemd.services.vaultwarden = {
      wantedBy = lib.mkIf (!cfg.active) (lib.mkForce []);
      serviceConfig.StateDirectory = lib.mkForce (lib.removePrefix "/var/lib/" cfg.stateDir);
    };

    systemd.services.vaultwarden-admin-token-env = {
      description = "Prepare Vaultwarden ADMIN_TOKEN environment file";
      before = [ "vaultwarden.service" ];
      requiredBy = [ "vaultwarden.service" ];
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        RuntimeDirectory = "alanix-vaultwarden";
        RuntimeDirectoryMode = "0700";
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -euo pipefail

        TOKEN_PATH=${lib.escapeShellArg config.sops.secrets.${cfg.adminTokenSecret}.path}
        ENV_PATH=/run/alanix-vaultwarden/admin-token.env
        TOKEN="$(tr -d '\r\n' < "$TOKEN_PATH")"

        if [ -z "$TOKEN" ]; then
          echo "Vaultwarden admin token is empty in $TOKEN_PATH" >&2
          exit 1
        fi

        umask 077
        printf 'ADMIN_TOKEN=%s\n' "$TOKEN" > "$ENV_PATH"
      '';
    };

    users.groups.vaultwarden = lib.mkMerge [
      {}
      (lib.mkIf (cfg.gid != null) { gid = cfg.gid; })
    ];
    users.users.vaultwarden = lib.mkMerge [
      {}
      (lib.mkIf (cfg.uid != null) { uid = cfg.uid; })
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 vaultwarden vaultwarden - -"
    ];

    services.caddy = lib.mkIf (cfg.wanAccess.enable || cfg.wireguardAccess.enable || cfg.torAccess.enable) {
      enable = true;
      virtualHosts = lib.mkMerge [
        (lib.mkIf cfg.wanAccess.enable {
          "${cfg.wanAccess.domain}".extraConfig = ''
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString cfg.port}
          '';
        })
        (lib.mkIf cfg.wireguardAccess.enable {
          "http://${cfg.wireguardAccess.listenAddress}:${toString cfg.wireguardAccess.port}".extraConfig = ''
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString cfg.port}
          '';
        })
        (lib.mkIf cfg.torAccess.enable {
          ":${toString cfg.torAccess.localPort}".extraConfig = ''
            bind 127.0.0.1
            encode zstd gzip
            reverse_proxy 127.0.0.1:${toString cfg.port}
          '';
        })
      ];
    };

    services.tor = lib.mkIf cfg.torAccess.enable {
      enable = true;
      relay.onionServices.${cfg.torAccess.serviceName} =
        {
          version = cfg.torAccess.version;
          map = [
            {
              port = cfg.torAccess.virtualPort;
              target = {
                addr = "127.0.0.1";
                port = cfg.torAccess.localPort;
              };
            }
          ];
        }
        // lib.optionalAttrs (torSecretKeyPath != null) {
          secretKey = torSecretKeyPath;
        };
    };
  };
}
