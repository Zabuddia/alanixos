{ config, lib, ... }:
let
  cluster = config.alanix.cluster;
  unknownOverrideKeys = overrides:
    builtins.filter (nodeName: !(builtins.hasAttr nodeName cluster.nodes)) (builtins.attrNames overrides);
in
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

      priorityOverrides = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {};
        description = ''
          Optional per-node priority overrides for filebrowser failover/backups.
          Lower number means higher priority. Keys must match alanix.cluster.nodes.
          Nodes not listed here use alanix.cluster.nodes.<name>.priority.
        '';
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

    services.forgejo = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable cluster-managed forgejo service, failover, and DNS control.";
      };

      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 3000;
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/forgejo";
      };

      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned UID for forgejo service user/group across nodes.";
      };

      gid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned GID for forgejo service user/group across nodes.";
      };

      dataPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/forgejo"
        ];
      };

      wanAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable WAN/public access endpoint for forgejo.";
        };

        domain = lib.mkOption {
          type = lib.types.str;
          description = "Public FQDN for forgejo WAN access.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open TCP 80/443 for forgejo WAN access.";
        };

        canonicalRootUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional canonical ROOT_URL for forgejo (for example https://forgejo.example.com/).";
        };
      };

      wireguardAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a WireGuard-only access endpoint for forgejo.";
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
          description = "Enable a Tor onion-service access endpoint for forgejo.";
        };

        onionServiceName = lib.mkOption {
          type = lib.types.str;
          default = "forgejo";
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
        description = "Public SSH key allowed for forgejo failover sync/control.";
      };

      priorityOverrides = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {};
        description = ''
          Optional per-node priority overrides for forgejo failover/backups.
          Lower number means higher priority. Keys must match alanix.cluster.nodes.
          Nodes not listed here use alanix.cluster.nodes.<name>.priority.
        '';
      };

      backups = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable restic backups for forgejo data.";
        };

        passwordSecret = lib.mkOption {
          type = lib.types.str;
          default = "restic/cluster-password";
          description = "sops secret containing the restic password used for forgejo backup repositories.";
        };

        repositoryBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/var/backups/restic/forgejo";
          description = "Base directory on each node used for incoming forgejo restic repositories.";
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "hourly";
          description = "Systemd OnCalendar schedule used for forgejo restic jobs.";
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
          description = "Retention policy for forgejo restic snapshots.";
        };
      };
    };
  };

  config.assertions = [
    {
      assertion = (unknownOverrideKeys cluster.services.filebrowser.priorityOverrides) == [];
      message =
        "alanix.cluster.services.filebrowser.priorityOverrides contains unknown nodes: "
        + lib.concatStringsSep ", " (unknownOverrideKeys cluster.services.filebrowser.priorityOverrides);
    }
    {
      assertion = (unknownOverrideKeys cluster.services.forgejo.priorityOverrides) == [];
      message =
        "alanix.cluster.services.forgejo.priorityOverrides contains unknown nodes: "
        + lib.concatStringsSep ", " (unknownOverrideKeys cluster.services.forgejo.priorityOverrides);
    }
  ];
}
