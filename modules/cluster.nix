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

    syncPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "Public SSH key shared by all service failover/sync controllers.";
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
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable cluster-managed filebrowser service, failover, and DNS control.";
      };

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

      users = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this File Browser user is an admin.";
            };

            scope = lib.mkOption {
              type = lib.types.str;
              default = "users/${name}";
              description = "User scope relative to alanix.filebrowser.root (for example users/buddia or .).";
            };

            password = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Plaintext password for this File Browser user (simple, not recommended).";
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to file containing plaintext password for this File Browser user.";
            };

            passwordSecret = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "sops secret name containing plaintext password for this File Browser user.";
            };
          };
        }));
        default = {};
        description = "Declarative File Browser users.";
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

        enableHttp = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose plaintext HTTP over Tor for filebrowser.";
        };

        httpLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 18088;
          description = "Local Caddy HTTP listener port used as hidden-service backend.";
        };

        httpVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 80;
          description = "Virtual Tor hidden-service HTTP port exposed to clients.";
        };

        enableHttps = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose HTTPS over Tor for filebrowser.";
        };

        httpsLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 18443;
          description = "Local Caddy HTTPS listener port used as hidden-service backend.";
        };

        httpsVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 443;
          description = "Virtual Tor hidden-service HTTPS port exposed to clients.";
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

      users = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            admin = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            email = lib.mkOption {
              type = lib.types.str;
              default = "${name}@local.invalid";
            };

            fullName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };

            userType = lib.mkOption {
              type = lib.types.enum [ "individual" "bot" ];
              default = "individual";
            };

            restricted = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            mustChangePassword = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            password = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Plaintext password for this Forgejo user (simple, not recommended).";
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to file containing plaintext password for this Forgejo user.";
            };

            passwordSecret = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "sops secret name containing plaintext password for this Forgejo user.";
            };
          };
        }));
        default = {};
        description = "Declarative Forgejo users.";
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

        enableHttp = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose plaintext HTTP over Tor for forgejo.";
        };

        httpLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 13000;
          description = "Local Caddy HTTP listener port used as hidden-service backend.";
        };

        httpVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 80;
          description = "Virtual Tor hidden-service HTTP port exposed to clients.";
        };

        enableHttps = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose HTTPS over Tor for forgejo.";
        };

        httpsLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 13443;
          description = "Local Caddy HTTPS listener port used as hidden-service backend.";
        };

        httpsVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 443;
          description = "Virtual Tor hidden-service HTTPS port exposed to clients.";
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

    services.invidious = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable cluster-managed Invidious service, failover, and DNS control.";
      };

      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 3100;
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/invidious";
      };

      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned UID for invidious service user/group across nodes.";
      };

      gid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned GID for invidious service user/group across nodes.";
      };

      settings = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Additional Invidious settings merged into services.invidious.settings.";
      };

      database = {
        createLocally = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to create and use a local PostgreSQL database.";
        };

        host = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Database host. null means local unix socket.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 5432;
          description = "Database port for Invidious.";
        };

        passwordSecret = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional sops secret containing Invidious database password.";
        };
      };

      hmacKeySecret = lib.mkOption {
        type = lib.types.str;
        default = "invidious/hmac-key";
        description = ''
          Required sops secret containing Invidious hmac_key.
          Set this secret in secrets/secrets.yaml to avoid per-node auto-generated keys.
        '';
      };

      companion = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable Invidious companion endpoint (implemented via inv-sig-helper on this nixpkgs version).";
        };

        listenAddress = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1:2999";
          description = "TCP listen address for the companion endpoint.";
        };
      };

      users = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
          options = {
            password = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Plaintext password for this Invidious user (simple, not recommended).";
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to file containing plaintext password for this Invidious user.";
            };

            passwordSecret = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "sops secret name containing plaintext password for this Invidious user.";
            };
          };
        }));
        default = {};
        description = ''
          Declarative Invidious users.
          Attribute names are Invidious login IDs (its "email" field), for example `buddia` or `buddia@example.com`.
        '';
      };

      dataPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/invidious"
          "/var/lib/postgresql"
        ];
      };

      wanAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable WAN/public access endpoint for invidious.";
        };

        domain = lib.mkOption {
          type = lib.types.str;
          description = "Public FQDN for invidious WAN access.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open TCP 80/443 for invidious WAN access.";
        };
      };

      wireguardAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a WireGuard-only access endpoint for invidious.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8092;
          description = "WireGuard-only access port exposed by Caddy.";
        };
      };

      torAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a Tor onion-service access endpoint for invidious.";
        };

        onionServiceName = lib.mkOption {
          type = lib.types.str;
          default = "invidious";
          description = "Service key name under services.tor.relay.onionServices.";
        };

        enableHttp = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose plaintext HTTP over Tor for invidious.";
        };

        httpLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 18300;
          description = "Local Caddy HTTP listener port used as hidden-service backend.";
        };

        httpVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 80;
          description = "Virtual Tor hidden-service HTTP port exposed to clients.";
        };

        enableHttps = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose HTTPS over Tor for invidious.";
        };

        httpsLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 18743;
          description = "Local Caddy HTTPS listener port used as hidden-service backend.";
        };

        httpsVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 443;
          description = "Virtual Tor hidden-service HTTPS port exposed to clients.";
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

      priorityOverrides = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {};
        description = ''
          Optional per-node priority overrides for invidious failover/backups.
          Lower number means higher priority. Keys must match alanix.cluster.nodes.
          Nodes not listed here use alanix.cluster.nodes.<name>.priority.
        '';
      };

      backups = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable restic backups for invidious data.";
        };

        passwordSecret = lib.mkOption {
          type = lib.types.str;
          default = "restic/cluster-password";
          description = "sops secret containing the restic password used for invidious backup repositories.";
        };

        repositoryBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/var/backups/restic/invidious";
          description = "Base directory on each node used for incoming invidious restic repositories.";
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "hourly";
          description = "Systemd OnCalendar schedule used for invidious restic jobs.";
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
          description = "Retention policy for invidious restic snapshots.";
        };
      };
    };

    services.vaultwarden = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable cluster-managed Vaultwarden service, failover, and DNS control.";
      };

      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 8222;
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/vaultwarden";
      };

      dbBackend = lib.mkOption {
        type = lib.types.enum [
          "sqlite"
          "mysql"
          "postgresql"
        ];
        default = "sqlite";
      };

      settings = lib.mkOption {
        type =
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
        default = {};
        description = "Additional Vaultwarden settings merged into services.vaultwarden.config.";
      };

      adminTokenSecret = lib.mkOption {
        type = lib.types.str;
        default = "vaultwarden/admin-token";
        description = ''
          Required sops secret path used by Vaultwarden admin UI.
          Secret content should be the raw admin token value.
        '';
      };

      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned UID for vaultwarden service user/group across nodes.";
      };

      gid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Pinned GID for vaultwarden service user/group across nodes.";
      };

      dataPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/var/lib/vaultwarden"
        ];
      };

      wanAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable WAN/public access endpoint for vaultwarden.";
        };

        domain = lib.mkOption {
          type = lib.types.str;
          description = "Public FQDN for vaultwarden WAN access.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open TCP 80/443 for vaultwarden WAN access.";
        };
      };

      wireguardAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a WireGuard-only access endpoint for vaultwarden.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8091;
          description = "WireGuard-only access port exposed by Caddy.";
        };
      };

      torAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a Tor onion-service access endpoint for vaultwarden.";
        };

        onionServiceName = lib.mkOption {
          type = lib.types.str;
          default = "vaultwarden";
          description = "Service key name under services.tor.relay.onionServices.";
        };

        enableHttp = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose plaintext HTTP over Tor for vaultwarden.";
        };

        httpLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 18222;
          description = "Local Caddy HTTP listener port used as hidden-service backend.";
        };

        httpVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 80;
          description = "Virtual Tor hidden-service HTTP port exposed to clients.";
        };

        enableHttps = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Expose HTTPS over Tor for vaultwarden.";
        };

        httpsLocalPort = lib.mkOption {
          type = lib.types.port;
          default = 18643;
          description = "Local Caddy HTTPS listener port used as hidden-service backend.";
        };

        httpsVirtualPort = lib.mkOption {
          type = lib.types.port;
          default = 443;
          description = "Virtual Tor hidden-service HTTPS port exposed to clients.";
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

      priorityOverrides = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {};
        description = ''
          Optional per-node priority overrides for vaultwarden failover/backups.
          Lower number means higher priority. Keys must match alanix.cluster.nodes.
          Nodes not listed here use alanix.cluster.nodes.<name>.priority.
        '';
      };

      backups = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable restic backups for vaultwarden data.";
        };

        passwordSecret = lib.mkOption {
          type = lib.types.str;
          default = "restic/cluster-password";
          description = "sops secret containing the restic password used for vaultwarden backup repositories.";
        };

        repositoryBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/var/backups/restic/vaultwarden";
          description = "Base directory on each node used for incoming vaultwarden restic repositories.";
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "hourly";
          description = "Systemd OnCalendar schedule used for vaultwarden restic jobs.";
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
          description = "Retention policy for vaultwarden restic snapshots.";
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
    {
      assertion = (unknownOverrideKeys cluster.services.invidious.priorityOverrides) == [];
      message =
        "alanix.cluster.services.invidious.priorityOverrides contains unknown nodes: "
        + lib.concatStringsSep ", " (unknownOverrideKeys cluster.services.invidious.priorityOverrides);
    }
    {
      assertion = (unknownOverrideKeys cluster.services.vaultwarden.priorityOverrides) == [];
      message =
        "alanix.cluster.services.vaultwarden.priorityOverrides contains unknown nodes: "
        + lib.concatStringsSep ", " (unknownOverrideKeys cluster.services.vaultwarden.priorityOverrides);
    }
  ];
}
