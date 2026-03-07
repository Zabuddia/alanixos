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

    syncSshKeySecret = lib.mkOption {
      type = lib.types.str;
      default = "cluster/sync-private-key";
      description = "sops secret containing the shared inter-node SSH private key for sync/control traffic.";
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
      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 8088;
      };

      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned UID for filebrowser service user/group across nodes.";
      };

      gid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned GID for filebrowser service user/group across nodes.";
      };

      dataPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/filebrowser"
          "/srv/filebrowser"
        ];
      };

      wanAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable WAN/public access endpoint for filebrowser.";
        };

        domain = lib.mkOption {
          type = lib.types.str;
          description = "Public FQDN for filebrowser WAN access.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open TCP 80/443 for filebrowser WAN access.";
        };
      };

      wireguardAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a WireGuard-only access endpoint for filebrowser.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8089;
          description = "WireGuard-only access port exposed by Caddy.";
        };
      };

      torAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a Tor onion-service access endpoint for filebrowser.";
        };

        onionServiceName = lib.mkOption {
          type = lib.types.str;
          default = "filebrowser";
          description = "Service key name under services.tor.relay.onionServices.";
        };

        localPort = lib.mkOption {
          type = lib.types.port;
          default = 18088;
          description = "Local Caddy listener port used as hidden-service backend.";
        };

        virtualPort = lib.mkOption {
          type = lib.types.port;
          default = 80;
          description = "Virtual Tor hidden-service port exposed to clients.";
        };

        version = lib.mkOption {
          type = lib.types.enum [ 2 3 ];
          default = 3;
          description = "Tor hidden-service version.";
        };

        secretKeySecret = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional sops secret containing hidden-service private key for stable onion address.";
        };
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

        passwordSecret = lib.mkOption {
          type = lib.types.str;
          default = "restic/cluster-password";
          description = "sops secret containing the restic password used for filebrowser backup repositories.";
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

    services.gitea = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable cluster-managed gitea service, failover, and DNS control.";
      };

      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 3000;
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/gitea";
      };

      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned UID for gitea service user/group across nodes.";
      };

      gid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned GID for gitea service user/group across nodes.";
      };

      dataPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/gitea"
        ];
      };

      wanAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable WAN/public access endpoint for gitea.";
        };

        domain = lib.mkOption {
          type = lib.types.str;
          description = "Public FQDN for gitea WAN access.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open TCP 80/443 for gitea WAN access.";
        };
      };

      wireguardAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a WireGuard-only access endpoint for gitea.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8090;
          description = "WireGuard-only access port exposed by Caddy.";
        };
      };

      torAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a Tor onion-service access endpoint for gitea.";
        };

        onionServiceName = lib.mkOption {
          type = lib.types.str;
          default = "gitea";
          description = "Service key name under services.tor.relay.onionServices.";
        };

        localPort = lib.mkOption {
          type = lib.types.port;
          default = 13000;
          description = "Local Caddy listener port used as hidden-service backend.";
        };

        virtualPort = lib.mkOption {
          type = lib.types.port;
          default = 80;
          description = "Virtual Tor hidden-service port exposed to clients.";
        };

        version = lib.mkOption {
          type = lib.types.enum [ 2 3 ];
          default = 3;
          description = "Tor hidden-service version.";
        };

        secretKeySecret = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional sops secret containing hidden-service private key for stable onion address.";
        };
      };

      syncPublicKey = lib.mkOption {
        type = lib.types.str;
        description = "Public SSH key allowed for gitea failover sync/control.";
      };

      backups = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable restic backups for gitea data.";
        };

        passwordSecret = lib.mkOption {
          type = lib.types.str;
          default = "restic/cluster-password";
          description = "sops secret containing the restic password used for gitea backup repositories.";
        };

        repositoryBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/var/backups/restic/gitea";
          description = "Base directory on each node used for incoming gitea restic repositories.";
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "hourly";
          description = "Systemd OnCalendar schedule used for gitea restic jobs.";
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
          description = "Retention policy for gitea restic snapshots.";
        };
      };
    };
  };
}
