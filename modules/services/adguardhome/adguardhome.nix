{ config, lib, pkgs, ... }:
let
  cfg = config.alanix.adguardhome;
  serviceExposure = import ../../../lib/mkServiceExposure.nix { inherit lib pkgs; };

  webEndpoint = {
    address = cfg.web.listenAddress;
    port = cfg.web.port;
    protocol = "http";
  };

  lanIPv4Cidrs = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];

  lanIPv6Cidrs = [
    "fc00::/7"
    "fe80::/10"
  ];

  mkIptablesLanRule =
    {
      command,
      source,
      protocol,
    }:
    "${command} -w -A nixos-fw -s ${source} -p ${protocol} --dport ${toString cfg.dns.port} -j nixos-fw-accept";

  lanFirewallIptablesRules = lib.concatStringsSep "\n" (
    lib.concatMap
      (source: [
        (mkIptablesLanRule { command = "iptables"; inherit source; protocol = "tcp"; })
        (mkIptablesLanRule { command = "iptables"; inherit source; protocol = "udp"; })
      ])
      lanIPv4Cidrs
    ++ lib.concatMap
      (source: [
        (mkIptablesLanRule { command = "ip6tables"; inherit source; protocol = "tcp"; })
        (mkIptablesLanRule { command = "ip6tables"; inherit source; protocol = "udp"; })
      ])
      lanIPv6Cidrs
  );

  lanFirewallNftRules = ''
    ip saddr { ${lib.concatStringsSep ", " lanIPv4Cidrs} } tcp dport ${toString cfg.dns.port} accept
    ip saddr { ${lib.concatStringsSep ", " lanIPv4Cidrs} } udp dport ${toString cfg.dns.port} accept
    ip6 saddr { ${lib.concatStringsSep ", " lanIPv6Cidrs} } tcp dport ${toString cfg.dns.port} accept
    ip6 saddr { ${lib.concatStringsSep ", " lanIPv6Cidrs} } udp dport ${toString cfg.dns.port} accept
  '';

  baseSettings = {
    protection_enabled = true;
    filtering_enabled = true;
    filters_update_interval = cfg.filtersUpdateInterval;

    dns = {
      bind_hosts = cfg.dns.bindHosts;
      port = cfg.dns.port;
      upstream_dns = cfg.dns.upstreamDns;
      bootstrap_dns = cfg.dns.bootstrapDns;
    };

    filters = cfg.filters;
  };
in
{
  options.alanix.adguardhome = {
    enable = lib.mkEnableOption "standalone AdGuard Home";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.adguardhome;
      defaultText = lib.literalExpression "pkgs.adguardhome";
      description = "AdGuard Home package to run.";
    };

    mutableSettings = lib.mkOption {
      type = lib.types.bool;
      description = "Allow AdGuard Home web UI changes to persist between restarts.";
    };

    filtersUpdateInterval = lib.mkOption {
      type = lib.types.ints.unsigned;
      description = "Filter update interval in hours.";
    };

    web = {
      listenAddress = lib.mkOption {
        type = lib.types.str;
        description = "AdGuard Home web UI bind address.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "AdGuard Home web UI port.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open the web UI port in the host firewall.";
      };
    };

    dns = {
      bindHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Addresses AdGuard Home should bind for DNS.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "DNS listener port.";
      };

      upstreamDns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Upstream resolvers used by AdGuard Home.";
      };

      bootstrapDns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Plain DNS resolvers used to bootstrap encrypted upstreams.";
      };

      openFirewallOnTailscale = lib.mkOption {
        type = lib.types.bool;
        description = "Open the DNS port on the Tailscale interface.";
      };

      openFirewallOnLan = lib.mkOption {
        type = lib.types.bool;
        description = "Open the DNS port to clients from private LAN address ranges.";
      };
    };

    filters = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = "AdGuard Home filter lists.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra settings recursively merged into services.adguardhome.settings.";
    };

    expose = serviceExposure.mkOptions {
      serviceName = "adguardhome";
      serviceDescription = "AdGuard Home";
      defaultPublicPort = 3000;
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.dns.openFirewallOnTailscale || config.services.tailscale.enable;
          message = "alanix.adguardhome.dns.openFirewallOnTailscale requires services.tailscale.enable = true.";
        }
        {
          assertion = !cfg.dns.openFirewallOnLan || builtins.elem config.networking.firewall.backend [ "iptables" "nftables" ];
          message = "alanix.adguardhome.dns.openFirewallOnLan only supports the iptables and nftables firewall backends.";
        }
      ] ++ serviceExposure.mkAssertions {
        inherit config;
        optionPrefix = "alanix.adguardhome.expose";
        endpoint = webEndpoint;
        exposeCfg = cfg.expose;
      };

      services.adguardhome = {
        enable = true;
        package = cfg.package;
        host = cfg.web.listenAddress;
        port = cfg.web.port;
        mutableSettings = cfg.mutableSettings;
        openFirewall = cfg.web.openFirewall;
        settings = lib.recursiveUpdate baseSettings cfg.settings;
      };

      networking.firewall.interfaces.${config.services.tailscale.interfaceName} =
        lib.mkIf cfg.dns.openFirewallOnTailscale {
          allowedTCPPorts = [ cfg.dns.port ];
          allowedUDPPorts = [ cfg.dns.port ];
        };

      networking.firewall.extraCommands =
        lib.mkIf (cfg.dns.openFirewallOnLan && config.networking.firewall.backend == "iptables")
          lanFirewallIptablesRules;

      networking.firewall.extraInputRules =
        lib.mkIf (cfg.dns.openFirewallOnLan && config.networking.firewall.backend == "nftables")
          lanFirewallNftRules;
    }

    (serviceExposure.mkConfig {
      inherit config;
      endpoint = webEndpoint;
      exposeCfg = cfg.expose;
      serviceName = "adguardhome";
      serviceDescription = "AdGuard Home";
    })
  ]);
}
