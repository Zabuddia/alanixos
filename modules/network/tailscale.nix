{ lib, config, pkgs, pkgs-unstable, hostname, ... }:

let
  cfg = config.alanix.tailscale;
  secretFiles = import ../../secrets/files.nix;
  effectiveAuthKeySecret =
    if cfg.authKeySecret != null then
      cfg.authKeySecret
    else if cfg.authKeyFile == null && cfg.loginServer != null then
      "headscale/preauth-keys/${hostname}"
    else
      null;
  effectiveAuthKeyFile =
    if cfg.authKeyFile != null then
      cfg.authKeyFile
    else if effectiveAuthKeySecret != null then
      config.sops.secrets.${effectiveAuthKeySecret}.path
    else
      null;
  hasAdvertiseRoutes = cfg.advertiseRoutes != [ ];
  routingMode =
    if cfg.acceptRoutes && hasAdvertiseRoutes then
      "both"
    else if cfg.acceptRoutes then
      "client"
    else if hasAdvertiseRoutes then
      "server"
    else
      "none";
  preferenceFlags =
    lib.optionals cfg.acceptRoutes [ "--accept-routes=true" ]
    ++ lib.optionals hasAdvertiseRoutes [
      "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}"
    ]
    ++ lib.optionals (cfg.operator != null) [ "--operator=${cfg.operator}" ];
  loginFlags = lib.optionals (cfg.loginServer != null) [
    "--login-server=${cfg.loginServer}"
  ];
  effectiveMagicDnsDomains =
    if cfg.magicDnsDomains != [ ] then
      cfg.magicDnsDomains
    else if cfg.loginServer != null then
      [ "tail.fifefin.com" ]
    else
      [ "ts.net" ];
  magicDnsKresdConfig =
    domain:
    let
      dnsName = if lib.hasSuffix "." domain then domain else "${domain}.";
      luaName = builtins.toJSON dnsName;
    in
    ''
      trust_anchors.set_insecure({${luaName}})
      policy.add(policy.suffix(policy.FORWARD({'100.100.100.100'}), {kres.str2dname(${luaName})}))
    '';
in
{
  options.alanix.tailscale = {
    enable = lib.mkEnableOption "Tailscale";

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Declarative Tailscale address or MagicDNS name used by other repo modules for peer-to-peer connectivity.";
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept subnet routes advertised by other Tailscale nodes.";
    };

    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.168.1.0/24" ];
      description = "Subnet routes to advertise from this Tailscale node.";
    };

    operator = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Unix user allowed to operate Tailscale as an operator (e.g. for serve/funnel).";
    };

    loginServer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Tailscale-compatible control server URL, such as a Headscale server.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional file containing a Tailscale/Headscale auth key for declarative login. Overrides authKeySecret when set.";
    };

    authKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional SOPS secret containing a Tailscale/Headscale auth key for
        declarative login. When loginServer is set and authKeyFile is unset,
        this defaults to headscale/preauth-keys/<hostname> in secrets/network.yaml.
      '';
    };

    magicDnsDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        MagicDNS suffixes forwarded to Tailscale's local DNS server when kresd
        is the system resolver. Defaults to tail.fifefin.com for Headscale
        clients and ts.net for Tailscale SaaS clients.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.authKeyFile == null || cfg.authKeySecret == null;
          message = "alanix.tailscale.authKeyFile and alanix.tailscale.authKeySecret are mutually exclusive.";
        }
      ];

      sops.secrets =
        if effectiveAuthKeySecret == null then
          { }
        else
          {
            ${effectiveAuthKeySecret} = {
              sopsFile = secretFiles.network;
              owner = "root";
              group = "root";
              mode = "0400";
            };
          };

      services.tailscale = {
        enable = true;
        package = pkgs-unstable.tailscale;
        authKeyFile = effectiveAuthKeyFile;
        disableUpstreamLogging = cfg.loginServer != null;
        extraUpFlags = loginFlags;
        useRoutingFeatures = routingMode;
        extraSetFlags = preferenceFlags;
      };

      # Forward MagicDNS queries to 100.100.100.100 when kresd is the system resolver.
      # Without this, kresd can't resolve tailnet names and etcd peer connections fail.
      services.kresd.extraConfig = ''
        -- Tailscale/Headscale MagicDNS suffixes are not DNSSEC-signed, so mark
        -- them insecure to suppress validation failures.
        ${lib.concatMapStringsSep "\n" magicDnsKresdConfig effectiveMagicDnsDomains}
      '';

      systemd.services.alanix-tailscale-ready = {
        description = "Wait for Tailscale interface readiness";
        after = [ "tailscaled.service" ];
        wants = [ "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "30s";
        };
        script = ''
          set -euo pipefail

          iface="${config.services.tailscale.interfaceName}"

          for _ in $(seq 1 60); do
            if ${pkgs.iproute2}/bin/ip link show dev "$iface" >/dev/null 2>&1 \
              && ${config.services.tailscale.package}/bin/tailscale ip -4 | grep -q .; then
              exit 0
            fi
            sleep 1
          done

          echo "Timed out waiting for Tailscale interface $iface to become ready" >&2
          exit 1
        '';
      };
    }
  ]);
}
