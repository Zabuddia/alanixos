{ lib, ... }:
{
  options.alanix.cluster = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Primary DNS domain for this cluster.";
    };

    dns = {
      provider = lib.mkOption {
        type = lib.types.enum [ "cloudflare" ];
        default = "cloudflare";
        description = "DNS provider backend for API-driven updates.";
      };

      apiTokenSecret = lib.mkOption {
        type = lib.types.str;
        default = "cloudflare/api-token";
        description = "sops secret containing DNS provider API token.";
      };
    };

    wgSubnetCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.0/24";
      description = "WireGuard subnet CIDR used for inter-node traffic.";
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
        options = {
          vpnIP = lib.mkOption {
            type = lib.types.str;
            description = "WireGuard VPN IP for this node.";
          };

          priority = lib.mkOption {
            type = lib.types.int;
            description = "Lower number means higher priority for active role.";
          };

          wireguardPublicKey = lib.mkOption {
            type = lib.types.str;
          };

          wireguardEndpointHost = lib.mkOption {
            type = lib.types.str;
          };

          wireguardListenPort = lib.mkOption {
            type = lib.types.port;
            default = 51820;
          };

          ddnsRecord = lib.mkOption {
            type = lib.types.str;
            default = config.wireguardEndpointHost;
            description = "FQDN record this node keeps updated to its public IP.";
          };

          sshTarget = lib.mkOption {
            type = lib.types.str;
            default = "root@${config.vpnIP}";
            description = "SSH target used for inter-node sync/control.";
          };
        };
      }));
      description = "Cluster node definitions keyed by hostname.";
    };

    services.filebrowser = {
      domain = lib.mkOption {
        type = lib.types.str;
        description = "Public FQDN for filebrowser.";
      };

      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 8088;
      };

      dataPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/filebrowser"
          "/srv/filebrowser"
        ];
      };

      reverseProxyOpenFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      syncPublicKey = lib.mkOption {
        type = lib.types.str;
        description = "Public SSH key allowed for failover sync/control.";
      };

      backups = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable restic backups for filebrowser.";
        };

        repositoryBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/var/backups/restic/filebrowser";
          description = "Base directory on each node used for incoming filebrowser restic repositories.";
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "hourly";
          description = "Systemd OnCalendar schedule used for filebrowser restic jobs.";
        };

        randomizedDelaySec = lib.mkOption {
          type = lib.types.str;
          default = "10m";
        };

        pruneOpts = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "--keep-hourly 24"
            "--keep-daily 7"
            "--keep-weekly 4"
            "--keep-monthly 6"
          ];
          description = "Retention policy for filebrowser restic snapshots.";
        };
      };
    };
  };
}
