{ config, lib, ... }:

let
  cfg = config.alanix.unbound;

  toDnsName = domain: if lib.hasSuffix "." domain then domain else "${domain}.";

  effectiveMagicDnsDomains =
    if cfg.magicDnsDomains != [ ] then
      cfg.magicDnsDomains
    else if config.alanix.tailscale.magicDnsDomains != [ ] then
      config.alanix.tailscale.magicDnsDomains
    else if config.alanix.tailscale.loginServer != null then
      [ "tail.fifefin.com" ]
    else
      [ "ts.net" ];

  magicDnsNames = map toDnsName effectiveMagicDnsDomains;
in
{
  options.alanix.unbound = {
    enable = lib.mkEnableOption "Unbound recursive DNS resolver";

    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1" ] ++ lib.optional config.networking.enableIPv6 "::1";
      description = "Addresses Unbound should bind. Keep this loopback-only when AdGuard Home is the exposed DNS service.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 53;
      description = "Unbound DNS listener port.";
    };

    resolveLocalQueries = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use Unbound for local system DNS resolution.";
    };

    forwardMagicDns = lib.mkOption {
      type = lib.types.bool;
      default = config.alanix.tailscale.enable;
      defaultText = "config.alanix.tailscale.enable";
      description = "Forward Tailscale/Headscale MagicDNS zones to the local Tailscale DNS proxy.";
    };

    magicDnsDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "MagicDNS suffixes forwarded to Tailscale. When empty, alanix.tailscale.magicDnsDomains is used.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra settings merged into services.unbound.settings.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.unbound = {
      enable = true;
      resolveLocalQueries = cfg.resolveLocalQueries;
      settings = lib.mkMerge [
        {
          server = {
            interface = cfg.listenAddresses;
            port = cfg.port;
            do-ip4 = true;
            do-ip6 = config.networking.enableIPv6;
            do-udp = true;
            do-tcp = true;
            harden-glue = true;
            harden-dnssec-stripped = true;
            qname-minimisation = true;
            aggressive-nsec = true;
            prefetch = true;
            hide-identity = true;
            hide-version = true;
            minimal-responses = true;
          } // lib.optionalAttrs cfg.forwardMagicDns {
            domain-insecure = magicDnsNames;
          };
        }
        (lib.mkIf cfg.forwardMagicDns {
          forward-zone = map
            (name: {
              inherit name;
              forward-addr = [ "100.100.100.100" ];
              forward-first = false;
            })
            magicDnsNames;
        })
        cfg.settings
      ];
    };
  };
}
