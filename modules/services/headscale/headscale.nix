{ config, lib, pkgs, ... }:

let
  cfg = config.alanix.headscale;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };
  policy =
    {
      acls = [
        {
          action = "accept";
          src = [ "*" ];
          dst = [ "*:*" ];
        }
      ];
    }
    // lib.optionalAttrs (cfg.routeAutoApprovers != { }) {
      autoApprovers = {
        routes = cfg.routeAutoApprovers;
      };
    };
  policyFile = pkgs.writeText "alanix-headscale-policy.hujson" (builtins.toJSON policy);
in
{
  options.alanix.headscale = {
    enable = lib.mkEnableOption "Headscale control server";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Local Headscale HTTP listen address.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8086;
      description = "Local Headscale HTTP listen port.";
    };

    serverUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://headscale.fifefin.com";
      description = "Public Headscale URL used by clients.";
    };

    baseDomain = lib.mkOption {
      type = lib.types.str;
      default = "tail.fifefin.com";
      description = "MagicDNS base domain for Headscale nodes.";
    };

    dns = {
      overrideLocalDns = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether Headscale should override clients' local DNS settings.";
      };

      nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "45.90.28.226" "45.90.30.226" ];
        description = "Global DNS resolvers pushed to Headscale clients.";
      };

      searchDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional DNS search domains pushed to Headscale clients.";
      };
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/headscale";
      readOnly = true;
      description = "Headscale state directory managed by the NixOS module.";
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cluster backup staging directory. Required when cluster.enable = true.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          email = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional Headscale user email.";
          };

          displayName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional Headscale user display name.";
          };
        };
      });
      default = {
        buddia = {
          email = "fife.alan@protonmail.com";
          displayName = "Alan Fife";
        };
      };
      description = "Headscale users reconciled on the active cluster leader.";
    };

    routeAutoApprovers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        "192.168.10.0/24" = [ "fife.alan@protonmail.com" ];
      };
      description = "Headscale policy auto-approvers for advertised subnet routes.";
    };

    derp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable Headscale's embedded DERP server.";
      };

      stunPort = lib.mkOption {
        type = lib.types.port;
        default = 3478;
        description = "UDP STUN port for embedded DERP NAT traversal.";
      };

      useUpstreamDerpMap = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to include Tailscale's public DERP map alongside the embedded DERP server.";
      };
    };

    expose = serviceExposure.mkOptions {
      serviceName = "headscale";
      serviceDescription = "Headscale";
      defaultPublicPort = 443;
    };

    cluster = {
      enable = lib.mkEnableOption "cluster-managed Headscale";

      backupInterval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = "How often the cluster leader backs up Headscale state.";
      };

      maxBackupAge = lib.mkOption {
        type = lib.types.str;
        default = "2h";
        description = "Maximum acceptable age of a Headscale backup for normal failover.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.cluster.enable || cfg.backupDir != null;
          message = "alanix.headscale.cluster.enable requires alanix.headscale.backupDir to be set.";
        }
        {
          assertion = cfg.backupDir == null || lib.hasPrefix "/" cfg.backupDir;
          message = "alanix.headscale.backupDir must be an absolute path when set.";
        }
        {
          assertion = cfg.serverUrl != "https://${cfg.baseDomain}";
          message = "alanix.headscale.baseDomain must differ from alanix.headscale.serverUrl.";
        }
      ] ++ serviceExposure.mkAssertions {
        inherit config;
        optionPrefix = "alanix.headscale.expose";
        endpoint = {
          address = cfg.listenAddress;
          port = cfg.port;
          protocol = "http";
        };
        exposeCfg = cfg.expose;
      };

      services.headscale = {
        enable = true;
        address = cfg.listenAddress;
        port = cfg.port;
        settings = {
          server_url = cfg.serverUrl;
          trusted_proxies = [ "127.0.0.1/32" ];
          prefixes = {
            v4 = "100.64.0.0/10";
            v6 = "fd7a:115c:a1e0::/48";
            allocation = "sequential";
          };
          database = {
            type = "sqlite";
            sqlite = {
              path = "${cfg.stateDir}/db.sqlite";
              write_ahead_log = true;
            };
          };
          derp = {
            server = {
              enabled = cfg.derp.enable;
              region_id = 999;
              region_code = "alanix";
              region_name = "Alanix DERP";
              verify_clients = true;
              stun_listen_addr = "0.0.0.0:${toString cfg.derp.stunPort}";
              private_key_path = "${cfg.stateDir}/derp_server_private.key";
            };
            urls = lib.optional cfg.derp.useUpstreamDerpMap "https://controlplane.tailscale.com/derpmap/default";
            paths = [ ];
            auto_update_enabled = cfg.derp.useUpstreamDerpMap;
            update_frequency = "24h";
          };
          dns = {
            magic_dns = true;
            base_domain = cfg.baseDomain;
            override_local_dns = cfg.dns.overrideLocalDns;
            nameservers.global = cfg.dns.nameservers;
            search_domains = cfg.dns.searchDomains;
          };
          policy = {
            mode = "file";
            path = policyFile;
          };
          log = {
            level = "info";
            format = "text";
          };
        };
      };

      networking.firewall.allowedUDPPorts = lib.optionals cfg.derp.enable [ cfg.derp.stunPort ];

      environment.systemPackages = [ config.services.headscale.package ];
    }

    (serviceExposure.mkConfig {
      serviceName = "headscale";
      serviceDescription = "Headscale";
      inherit config;
      endpoint = {
        address = cfg.listenAddress;
        port = cfg.port;
        protocol = "http";
      };
      exposeCfg = cfg.expose;
    })
  ]);
}
