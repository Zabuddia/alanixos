{ config, lib, hostname, ... }:

let
  cfg = config.alanix.adguardhome;
  clusterCfg = cfg.cluster;

  resolverHosts =
    if clusterCfg.resolverHosts != [ ] then
      clusterCfg.resolverHosts
    else if config.alanix.cluster.members != [ ] then
      config.alanix.cluster.members
    else
      builtins.attrNames clusterCfg.resolverAddresses;

  hasResolverAddress = host: builtins.hasAttr host clusterCfg.resolverAddresses;
  missingResolverHosts = lib.filter (host: !(hasResolverAddress host)) resolverHosts;
  localResolverAddress = clusterCfg.resolverAddresses.${hostname} or null;
  localLanBindHosts = clusterCfg.lanBindHosts.${hostname} or [ ];
  localBindHosts = lib.optional (localResolverAddress != null) localResolverAddress ++ localLanBindHosts;
  headscaleNameservers = map (host: clusterCfg.resolverAddresses.${host}) (lib.filter hasResolverAddress resolverHosts);
in
{
  options.alanix.adguardhome.cluster = {
    enable = lib.mkEnableOption "cluster-wide AdGuard Home DNS wiring";

    resolverAddresses = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        alan-big-nixos = "100.64.0.3";
        alan-node = "100.64.0.5";
      };
      description = "Tailnet DNS listener addresses for AdGuard Home, keyed by hostname.";
    };

    resolverHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Ordered resolver hostnames to publish through Headscale DNS. When empty,
        the cluster members are used, falling back to resolverAddresses keys.
      '';
    };

    lanBindHosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        alan-big-nixos = [ "192.168.10.225" ];
      };
      description = "Extra LAN addresses AdGuard Home should bind on each host.";
    };

    publishHeadscaleNameservers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Publish the cluster AdGuard Home resolvers as Headscale global nameservers.";
    };
  };

  config = lib.mkIf clusterCfg.enable {
    assertions = [
      {
        assertion = localResolverAddress != null;
        message = "alanix.adguardhome.cluster.resolverAddresses must include ${hostname}.";
      }
      {
        assertion = missingResolverHosts == [ ];
        message = "alanix.adguardhome.cluster.resolverAddresses is missing entries for: ${lib.concatStringsSep ", " missingResolverHosts}.";
      }
    ];

    alanix.adguardhome.dns = {
      bindHosts = lib.mkDefault localBindHosts;
      openFirewallOnTailscale = lib.mkDefault true;
      openFirewallOnLan = lib.mkDefault (localLanBindHosts != [ ]);
    };

    alanix.headscale.dns.nameservers =
      lib.mkIf (clusterCfg.publishHeadscaleNameservers && config.alanix.headscale.enable)
        (lib.mkDefault headscaleNameservers);
  };
}
